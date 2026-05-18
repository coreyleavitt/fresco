## OTP-flavored supervisor.
##
## v2.0 surface: oneForOne strategy + lifecycle types
## (`lcPermanent` / `lcTransient` / `lcTemporary`) + restart-rate
## windowing. Other strategies (oneForAll, restForOne) and dynamic
## pools land in v2.3. Per-exception `onError` policies and state-
## restoration on restart land in v2.2.
##
##   let sup = newSupervisor(maxRestarts = 5, within = 10.seconds)
##   sup.addChild("heartbeat", lcPermanent, heartbeatFactory)
##   sup.addChild("agent",     lcTransient, agentFactory)
##   await spawn sup.run()
##
## A factory is `proc(): Future[void]` — the same shape as an async
## proc invocation. The supervisor calls the factory each time it
## (re)starts the child.

import std/[macros, tables, sets, options]
import chronos
import chronos/contextvars
import ./core
import ./group

import ../reactive/scope
import ../reactive/capabilities
import ../journal/events as jev
import ../journal/log

export group
export capabilities
export options

type
  Lifecycle* = enum
    lcPermanent     ## always restart, success or failure
    lcTransient     ## restart only on abnormal exit (failure or cancel)
    lcTemporary     ## never restart

  Strategy* = enum
    ssOneForOne      ## restart only the failing child
    ssOneForAll      ## any failure → cancel all siblings, restart all
    ssRestForOne     ## any failure → cancel this child + all *later* siblings
                    ## (declaration order), restart that group

  ErrorAction* = enum
    eaRestart       ## restart the child (subject to maxRestarts window)
    eaEscalate      ## raise SupervisorEscalation
    eaTerminate     ## remove the child (treat as terminal completion)

  ErrorPolicy* = proc(e: ref Exception): ErrorAction
                 {.closure, gcsafe, raises: [].}
    ## Per-child error mapper. Inspects the failing future's exception
    ## and decides how the supervisor should respond. nil means
    ## "use the lifecycle default (restart for permanent/transient).

  RestartHandler* = proc(j: Journal, previousTaskId: TaskId)
                    {.closure, gcsafe.}
    ## Fires before each *restart* (not the initial spawn) with the
    ## journal and the previous taskId. Typical use: walk
    ## `journal.lastWritesByLabel(previousTaskId)` and restore state
    ## from `ekSignalWrite` events. Restoration happens out of band —
    ## the factory will still be called fresh after the handler.
    ##
    ## **Prerequisite:** the handler only fires when `globalJournal`
    ## is set (since state restoration without journal-backed history
    ## is meaningless). If you need a side-effect on every restart
    ## regardless, install an `onError` policy that returns
    ## `eaRestart` after running the side-effect — that path runs
    ## unconditionally.

  ChildSpec* = object
    name*: string
    lifecycle*: Lifecycle
    factory*: ChildFactory
    onError*: ErrorPolicy
    onRestart*: RestartHandler

  ChildState = ref object
    spec: ChildSpec
    mount: Mount
    restartTimes: seq[Moment]

  AdoptedGroup = ref object
    name: string
    group: TaskGroup
    lifecycle: Lifecycle
    maxRestarts: int
    within: Duration
    restartTimes: seq[Moment]
    mountFactories: Table[ptr Mount, ChildFactory]
      ## Indexed by the raw Mount ref's memory address (Mount is a
      ## ref object; using the ref pointer is stable for its lifetime
      ## and avoids requiring `hash` for Mount itself).
    members: seq[Mount]
      ## Snapshot of the group's current members from the supervisor's
      ## perspective. Updated by the spawn hook on add and by the
      ## supervisor on restart. Kept separately from the group's own
      ## member list because the group's auto-remove callback fires
      ## eagerly on member finish (clearing the group's view) while
      ## the supervisor needs to retain the factory until it has
      ## decided whether to restart.

  Supervisor* = ref object of RootObj
    strategy*: Strategy
    maxRestarts*: int
    within*: Duration
    children: seq[ChildState]
    adoptedGroups: seq[AdoptedGroup]
    wakeup: Future[void]
      ## Completed by adopted-group spawn hooks to wake the run-loop
      ## race when new members are added. Re-created at the top of
      ## each iteration.

  SupervisorEscalation* = object of CatchableError
    childName*: string

contextVar:
  var currentSupervisor: Supervisor = nil
  ## Chronos contextVar carrying the supervisor that spawned the
  ## currently-running task. Set by `Supervisor.run()` around each
  ## child factory call; the chronos dispatcher captures+restores
  ## across every await automatically. Inside a `{.needs.}`-annotated
  ## task body, the macro-injected `currentSup()` accessor reads this
  ## and downcasts to the proc-local synthetic supervisor type.

proc newSupervisor*(strategy = ssOneForOne,
                    maxRestarts = 5,
                    within = 10.seconds): Supervisor =
  ## Construct a supervisor. Defaults mirror OTP's typical values:
  ## up to `maxRestarts` (5) restarts within a `within` (10s) sliding
  ## window before the supervisor escalates. `strategy` controls how
  ## cascades propagate among siblings (`ssOneForOne` restarts only
  ## the failing child; see Strategy doc).
  Supervisor(
    strategy: strategy,
    maxRestarts: maxRestarts,
    within: within)

proc addChild*(s: Supervisor, name: string,
               lifecycle: Lifecycle, factory: ChildFactory,
               onError: ErrorPolicy = nil,
               onRestart: RestartHandler = nil) =
  ## Register a child to be started when `run()` begins. `name` is
  ## used in journal entries for traceability. `lifecycle` decides
  ## whether to restart on each kind of exit (see Lifecycle doc).
  ## `onError` (optional) inspects the failing future's exception and
  ## returns an ErrorAction (eaRestart/eaEscalate/eaTerminate),
  ## overriding the lifecycle default. `onRestart` (optional, requires
  ## an installed journal) fires before each restart with the previous
  ## taskId so the handler can replay state via `lastWritesByLabel`.
  s.children.add ChildState(
    spec: ChildSpec(name: name, lifecycle: lifecycle,
                    factory: factory, onError: onError,
                    onRestart: onRestart))

proc hasAdoptedMembers(s: Supervisor): bool =
  for ag in s.adoptedGroups:
    if ag.members.len > 0: return true
  false

proc shouldRestart(lifecycle: Lifecycle, failed: bool): bool =
  case lifecycle
  of lcPermanent: true
  of lcTransient: failed
  of lcTemporary: false

proc trimWindow(times: var seq[Moment], now: Moment, window: Duration) =
  ## Drop entries older than `window` from the front. Uses a single
  ## scan + one slice instead of repeated O(N) `delete(0)` left-shifts.
  var keep = 0
  while keep < times.len and now - times[keep] > window:
    inc keep
  if keep > 0:
    times = times[keep ..< times.len]

proc adopt*(s: Supervisor, g: TaskGroup, name: string,
            lifecycle = lcTemporary,
            maxRestarts = 5,
            within = 10.seconds) =
  ## Adopt a TaskGroup as a supervised pool. The supervisor watches
  ## the group's members through its run loop; on member finish it
  ## applies `lifecycle` (lcTemporary: never restart; lcTransient:
  ## restart on failure only; lcPermanent: always restart) and uses
  ## the per-pool `maxRestarts`/`within` rate window to escalate
  ## crash storms.
  ##
  ## Pools are only valid under `ssOneForOne` — pool members are an
  ## independent cascade domain (they don't cascade to named children
  ## or to each other regardless of strategy). Calling `adopt` on a
  ## supervisor with another strategy is a `Defect`.
  doAssert s.strategy == ssOneForOne,
    "task group adoption requires ssOneForOne supervisor strategy"
  for ag in s.adoptedGroups:
    doAssert ag.name != name,
      "duplicate adopted group name: " & name
  for c in s.children:
    doAssert c.spec.name != name,
      "adopted group name collides with named child: " & name
  let ag = AdoptedGroup(name: name, group: g, lifecycle: lifecycle,
                       maxRestarts: maxRestarts, within: within)
  s.adoptedGroups.add ag
  let supRef = s
  let agRef = ag
  g.setSpawnHook(proc(m: Mount, factory: ChildFactory)
                 {.gcsafe, raises: [].} =
    agRef.mountFactories[cast[ptr Mount](m)] = factory
    agRef.members.add m
    # Wake the run loop so the new member joins the race.
    if supRef.wakeup != nil and not supRef.wakeup.finished:
      try: supRef.wakeup.complete()
      except CatchableError: discard)

proc run*(s: Supervisor) {.async: (raises: [CatchableError]).} =
  ## Run the supervisor loop. Returns when every child has reached a
  ## terminal state (lcTemporary done, or lcTransient exited cleanly,
  ## or rate limit escalated). Cancellation propagates: cancelling the
  ## supervisor task cancels every child.

  # Start each child once. Wrap each factory call so the chronos
  # contextVar substrate captures the supervisor as `currentSupervisor`
  # for the duration of the spawned task's lifetime — `currentSup()`
  # inside the task body reads this back.
  for child in s.children:
    withCurrentSupervisor(s):
      child.mount = spawn child.spec.factory()

  while s.children.len > 0 or s.hasAdoptedMembers():
    # Re-create the wakeup future each iteration. Spawn hooks on
    # adopted groups complete it to bring the loop back to re-snapshot
    # member futures (so a newly-spawned member that synchronously
    # crashes is observed without waiting for an unrelated event).
    s.wakeup = newFuture[void]("supervisor.wakeup")

    var futs: seq[FutureBase] = @[s.wakeup.FutureBase]
    for child in s.children:
      futs.add child.mount.future.FutureBase
    for ag in s.adoptedGroups:
      for m in ag.members:
        futs.add m.future.FutureBase
    let winner = await race(futs)

    # Wakeup fired (new member spawned) — re-snapshot the race set.
    if winner == s.wakeup.FutureBase:
      continue

    # Locate the winner: named child, adopted-group member, or neither
    # (already-handled phantom).
    var idx = -1
    for i, child in s.children:
      if child.mount.future.FutureBase == winner: idx = i; break

    if idx < 0:
      # Adopted-group member finished. Handle and continue.
      var poolHandled = false
      for ag in s.adoptedGroups:
        var memberIdx = -1
        for i, m in ag.members:
          if m.future.FutureBase == winner: memberIdx = i; break
        if memberIdx < 0: continue
        poolHandled = true
        let finishedMount = ag.members[memberIdx]
        let factoryPtr = cast[ptr Mount](finishedMount)
        let factory = ag.mountFactories.getOrDefault(factoryPtr)
        let failed = finishedMount.future.failed
        # Remove from supervisor's view (group auto-removes too).
        ag.members.delete(memberIdx)
        ag.mountFactories.del(factoryPtr)

        if shouldRestart(ag.lifecycle, failed) and factory != nil:
          # Rate window: aggregate across the pool.
          let now = Moment.now()
          ag.restartTimes.add now
          trimWindow(ag.restartTimes, now, ag.within)
          if ag.restartTimes.len > ag.maxRestarts:
            var err = newException(SupervisorEscalation,
              "adopted group '" & ag.name & "' exceeded " &
              $ag.maxRestarts & " restarts in " & $ag.within)
            err.childName = ag.name
            journalEvent:
              jrnl.logSupervisorEscalate(taskTid, parentEvt,
                                         ag.name, err.msg)
            # Cancel everything before escalating.
            for c in s.children:
              if not c.mount.future.finished: c.mount.cancel()
            for ag2 in s.adoptedGroups:
              for m in ag2.members:
                if not m.future.finished: m.cancel()
            raise err
          # Restart the member via the group: the spawn hook re-records
          # the (new) mount + factory and completes wakeup so the loop
          # picks it up next iteration.
          journalEvent:
            jrnl.logSupervisorRestart(taskTid, parentEvt, ag.name,
                                      ag.restartTimes.len)
          discard ag.group.spawn(factory)
        break
      if not poolHandled: continue
      continue

    let child = s.children[idx]
    let failed = child.mount.future.failed

    # Consult per-exception onError policy when failed and policy set.
    # `policyAction` is read only when `policyFired == true`; the
    # initial `eaRestart` is the zero-value default for ErrorAction
    # (first enum member), arbitrary, never reached without policyFired.
    var policyAction: ErrorAction
    var policyFired = false
    if failed and child.spec.onError != nil:
      let err = child.mount.future.error
      if err != nil:
        try:
          policyAction = child.spec.onError(err)
          policyFired = true
        except Exception:
          # User-supplied ErrorPolicy closure — if it raises, fall
          # back to the lifecycle default (treat as policyFired=false).
          discard

    if policyFired and policyAction == eaTerminate:
      journalEvent: jrnl.logSupervisorTerminate(taskTid, parentEvt, child.spec.name)
      s.children.delete(idx)
      continue

    if policyFired and policyAction == eaEscalate:
      var err = newException(SupervisorEscalation,
        "child '" & child.spec.name & "' onError requested escalation")
      err.childName = child.spec.name
      journalEvent:
        jrnl.logSupervisorEscalate(taskTid, parentEvt, child.spec.name, err.msg)
      for c in s.children:
        if not c.mount.future.finished: c.mount.cancel()
      raise err

    # A user `onError` policy returning `eaRestart` overrides the
    # lifecycle default. Without this gate, an `lcTemporary` child
    # whose policy says "restart me" would still be terminated
    # because shouldRestart(lcTemporary, _) is always false.
    let policyForcesRestart = policyFired and policyAction == eaRestart
    if not policyForcesRestart and
       not shouldRestart(child.spec.lifecycle, failed):
      journalEvent: jrnl.logSupervisorTerminate(taskTid, parentEvt, child.spec.name)
      s.children.delete(idx)
      continue

    # Determine the cascade group based on supervisor strategy.
    #   ssOneForOne:  just the failing child.
    #   ssRestForOne: failing child + every child declared after it.
    #   ssOneForAll:  every child.
    var cascade: seq[int] = @[]
    case s.strategy
    of ssOneForOne:
      cascade.add idx
    of ssRestForOne:
      for i in idx ..< s.children.len: cascade.add i
    of ssOneForAll:
      for i in 0 ..< s.children.len: cascade.add i

    # Rate-window every cascaded child, not just the originating one.
    # In oneForAll/restForOne a cascade *is* a restart event for every
    # member: if any has exceeded its window, escalate. Otherwise an
    # all-children-fail-on-init loop would bypass the limit because
    # only the unlucky triggering child gets counted each round.
    #
    # Timing semantic: `now` is captured at the failure moment, not at
    # restart-spawn time. The rate window measures "failures per
    # interval" — if cascade drain takes long, the window starts
    # ticking before the new instance spawns. This is the desired
    # behaviour for catching tight crash loops; if you want per-
    # restart-spawn timing instead, you want a different supervisor.
    let now = Moment.now()
    for i in cascade:
      s.children[i].restartTimes.add now
      trimWindow(s.children[i].restartTimes, now, s.within)
    var rateOffender = -1
    for i in cascade:
      if s.children[i].restartTimes.len > s.maxRestarts:
        rateOffender = i
        break
    if rateOffender >= 0:
      let offendingName = s.children[rateOffender].spec.name
      var err = newException(SupervisorEscalation,
        "child '" & offendingName & "' exceeded " &
        $s.maxRestarts & " restarts in " & $s.within)
      err.childName = offendingName
      journalEvent: jrnl.logSupervisorEscalate(taskTid, parentEvt, offendingName, err.msg)
      for c in s.children:
        if not c.mount.future.finished: c.mount.cancel()
      raise err

    # Cancel siblings in the cascade (the triggering child is already
    # finished). Then wait for cancellation cascades to settle.
    for i in cascade:
      if i != idx and not s.children[i].mount.future.finished:
        s.children[i].mount.cancel()
    for i in cascade:
      if i != idx:
        try: await s.children[i].mount.future
        except CancelledError:
          # We just called cancel() on this sibling above — its
          # CancelledError is expected, not a concurrent failure.
          discard
        except CatchableError as siblingErr:
          # A sibling that crashed simultaneously with the winner —
          # journal it so the failure isn't silently lost. The
          # original racing winner still drives the cascade decision.
          let siblingName = s.children[i].spec.name
          let reason = "concurrent failure during cascade: " & siblingErr.msg
          journalEvent: jrnl.logSupervisorEscalate(taskTid, parentEvt, siblingName, reason)

    # Re-spawn every cascaded child. Logging + onRestart handlers fire
    # per child so the journal records the full cascade.
    for i in cascade:
      let target = s.children[i]
      let targetName = target.spec.name
      let targetGen = target.restartTimes.len
      journalEvent: jrnl.logSupervisorRestart(taskTid, parentEvt, targetName, targetGen)

      if target.spec.onRestart != nil and globalJournal != nil and
         target.mount != nil and target.mount.scope != nil:
        let prevTid = target.mount.scope.taskId
        try: target.spec.onRestart(globalJournal, prevTid)
        except Exception: discard   # user-supplied closure

      withCurrentSupervisor(s):
        target.mount = spawn target.spec.factory()

# --- Topology introspection ----------------------------------------------

type
  NodeKind* = enum
    nkChild        ## named child registered via `addChild`
    nkPool         ## summary node for an adopted TaskGroup
    nkPoolMember   ## individual live member of an adopted TaskGroup

  TopologyNode* = object
    name*: string
    lifecycle*: Lifecycle
    running*: bool
    taskId*: jev.TaskId
    restartCount*: int
    kind*: NodeKind
    poolName*: string   ## set when `kind == nkPoolMember`
    poolSize*: int      ## set when `kind == nkPool` (live member count)
    poolMax*: int       ## set when `kind == nkPool` (configured maxSize)

proc topology*(s: Supervisor): seq[TopologyNode] =
  ## Snapshot of the supervisor's tree: named children first, then for
  ## each adopted group one `nkPool` summary followed by one
  ## `nkPoolMember` per live member. Member names use the synthetic
  ## form `"<poolName>#<taskId>"`. Useful for devtools panels and
  ## external monitoring.
  for child in s.children:
    var node = TopologyNode(
      kind: nkChild,
      name: child.spec.name,
      lifecycle: child.spec.lifecycle,
      restartCount: child.restartTimes.len)
    if child.mount != nil:
      node.running = not child.mount.future.finished
      if child.mount.scope != nil:
        node.taskId = child.mount.scope.taskId
    result.add node
  for ag in s.adoptedGroups:
    result.add TopologyNode(
      kind: nkPool,
      name: ag.name,
      lifecycle: ag.lifecycle,
      restartCount: ag.restartTimes.len,
      poolSize: ag.members.len,
      poolMax: ag.group.maxSize)
    for m in ag.members:
      var node = TopologyNode(
        kind: nkPoolMember,
        lifecycle: ag.lifecycle,
        poolName: ag.name)
      if m.scope != nil:
        node.taskId = m.scope.taskId
        node.name = ag.name & "#" & $m.scope.taskId.uint64
      else:
        node.name = ag.name & "#?"
      node.running = not m.future.finished
      result.add node

# --- Declarative supervisor: block ---------------------------------------

macro supervisor*(body: untyped): untyped =
  ## Anonymous unified supervisor (μb static-runtime bridge).
  ##
  ## Body recognizes `provides(A, B, ...)`, `child factoryIdent`, and
  ## config assignments (`strategy = ...`, `maxRestarts = ...`,
  ## `within = ...`). Emits a ref-object that inherits from
  ## `Supervisor` and carries grant tokens for every provided cap.
  ## Discharge of each `child` is a `when` check against the type's
  ## `Grants*` concept satisfaction. The returned value runs its
  ## declared children when `await sup.run()` is called.
  expectKind(body, nnkStmtList)
  # Cap collection (recursive across nested supervisor: blocks).
  var allCaps: HashSet[string]
  collectAllProvidedCapNames(body, allCaps)
  # Build the anonymous type: `ref object of Supervisor` + one grant
  # field per cap.
  let typeSym = genSym(nskType, "AnonSup")
  var fields = newNimNode(nnkRecList)
  var sortedCaps: seq[string]
  for n in allCaps: sortedCaps.add n
  for capName in sortedCaps:
    if capName notin capMetaTable:
      error("supervisor: capability `" & capName & "` not declared — " &
            "use `cap T` for user caps or one of the built-ins")
    let meta = capMetaTable[capName]
    fields.add nnkIdentDefs.newTree(
      ident(meta.grantField),
      ident(meta.grantType),
      newEmptyNode())
  let typeDef = nnkTypeSection.newTree(
    nnkTypeDef.newTree(
      typeSym,
      newEmptyNode(),
      nnkRefTy.newTree(
        nnkObjectTy.newTree(
          newEmptyNode(),
          nnkOfInherit.newTree(bindSym"Supervisor"),
          fields))))
  # Read config assignments from the body: `strategy = ...`,
  # `maxRestarts = N`, `within = D`. Unrecognized assignments error.
  const KnownConfigKeys = ["strategy", "maxRestarts", "within"]
  var strategyExpr  = bindSym"ssOneForOne"
  var maxRestartsExpr: NimNode = newLit(5)
  var withinExpr: NimNode = newCall(bindSym"seconds", newLit(10))
  for stmt in body:
    if stmt.kind != nnkAsgn: continue
    let key = stmt[0]
    let keyName =
      if key.kind in {nnkIdent, nnkSym, nnkOpenSymChoice}: key.strVal
      else: ""
    if keyName notin KnownConfigKeys:
      error("supervisor: unknown config key `" & key.repr &
            "` (expected one of " & $KnownConfigKeys & ")", key)
    case keyName
    of "strategy":    strategyExpr    = stmt[1]
    of "maxRestarts": maxRestartsExpr = stmt[1]
    of "within":      withinExpr      = stmt[1]
    else: discard
  # Constructor — Supervisor base fields use the resolved config exprs
  # (defaults match newSupervisor). Grant fields follow.
  var ctor = nnkObjConstr.newTree(
    typeSym,
    nnkExprColonExpr.newTree(ident("strategy"),    strategyExpr),
    nnkExprColonExpr.newTree(ident("maxRestarts"), maxRestartsExpr),
    nnkExprColonExpr.newTree(ident("within"),      withinExpr))
  for capName in sortedCaps:
    let meta = capMetaTable[capName]
    ctor.add nnkExprColonExpr.newTree(
      ident(meta.grantField),
      newCall(ident(meta.grantType)))
  # Walk body for child declarations. Three accepted shapes:
  #   child fooTask                              # defaults: name=ident, lcPermanent
  #   child fooTask, lcTransient                 # lifecycle override
  #   child("explicit", lcTemporary, fooTask)    # back-compat paren form
  var checks = newStmtList()
  let supVar = genSym(nskLet, "sup")
  var addChildCalls = newStmtList()
  # Flatten all `child` statements, recursing into nested
  # `supervisor:` blocks. Old semantics: nested blocks are
  # organizational, contributing children + provides to the outer
  # supervisor. Real nested runtime supervisor trees are a separate
  # feature.
  proc collectChildStmts(b: NimNode, acc: var seq[NimNode]) =
    for st in b:
      if st.kind in {nnkCommand, nnkCall} and
         st[0].kind == nnkIdent and st[0].strVal == "child":
        acc.add st
      elif st.kind == nnkCall and st[0].kind == nnkIdent and
           st[0].strVal == "supervisor" and st.len >= 2 and
           st[1].kind == nnkStmtList:
        collectChildStmts(st[1], acc)
  var childStmts: seq[NimNode]
  collectChildStmts(body, childStmts)
  for stmt in childStmts:
    var factoryIdent: NimNode
    var lifecycleExpr: NimNode
    var nameExpr: NimNode
    if stmt.kind == nnkCommand:
      # `child factoryIdent` or `child factoryIdent, lifecycle`
      factoryIdent = stmt[1]
      lifecycleExpr =
        if stmt.len >= 3: stmt[2]
        else: bindSym"lcPermanent"
      nameExpr = newLit(factoryIdent.repr)
    else:
      # `child("name", lifecycle, factoryIdent)` back-compat paren form
      if stmt.len != 4:
        error("supervisor: `child(...)` paren form expects exactly " &
              "three arguments (name, lifecycle, factory); got " &
              $(stmt.len - 1), stmt)
      nameExpr      = stmt[1]
      lifecycleExpr = stmt[2]
      factoryIdent  = stmt[3]
    let childName = factoryIdent.repr
    # Missing `{.needs.}` is treated as the empty cap set. Children
    # that don't touch capability-gated APIs (e.g., pure-compute tasks
    # imported from a runtime-supervisor-only consumer) compose
    # cleanly without forcing an explicit `{.needs: ().}` annotation.
    let required =
      if childName in procRequiresNames: procRequiresNames[childName]
      else: @[]
    let conjunction = conceptConjunctionFor(required, typeSym)
    let nameLit = newLit(childName)
    var requiredList, providedList, missingList = ""
    var providedSet: HashSet[string]
    for cn in sortedCaps: providedSet.incl cn
    for i, cn in required:
      if i > 0: requiredList.add ", "
      requiredList.add cn
      if cn notin providedSet:
        if missingList.len > 0: missingList.add ", "
        missingList.add cn
    for i, cn in sortedCaps:
      if i > 0: providedList.add ", "
      providedList.add cn
    let requiredLit = newLit(requiredList)
    let providedLit = newLit(providedList)
    let missingLit  = newLit(missingList)
    checks.add quote do:
      when not (`conjunction`):
        {.error: "fresco capability discharge failed for `child " &
                 `nameLit` & "`: required {" & `requiredLit` &
                 "}, supervisor provides {" & `providedLit` &
                 "}, missing {" & `missingLit` &
                 "} — add the missing caps to a `provides(...)` " &
                 "line in this supervisor or an ancestor.".}
    let factoryClosure = quote do:
      proc(): Future[void] {.closure, gcsafe, raises: [].} =
        `factoryIdent`()
    addChildCalls.add quote do:
      addChild(`supVar`, `nameExpr`, `lifecycleExpr`, `factoryClosure`)
  # Assemble: type def, discharge checks, value binding, addChild calls,
  # final expression yielding the supervisor.
  result = nnkBlockExpr.newTree(
    newEmptyNode(),
    nnkStmtList.newTree(
      typeDef,
      checks,
      newLetStmt(supVar, ctor),
      addChildCalls,
      supVar))

macro supervisor*(name: untyped, body: untyped): untyped =
  ## Named supervisor declaration — emits `let <name> = supervisor: <body>`,
  ## delegating to the anonymous-form macro above. Same body grammar:
  ## `provides(...)`, `child <factory>` (with optional comma-lifecycle),
  ## `child("name", lifecycle, factory)` paren form, and config
  ## assignments (`maxRestarts`, `strategy`, `within`).
  expectKind(body, nnkStmtList)
  result = newLetStmt(name, newCall(bindSym"supervisor", body))
