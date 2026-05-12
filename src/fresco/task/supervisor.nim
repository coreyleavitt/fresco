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

import std/macros
import chronos
import ./core

import ../reactive/scope
import ../journal/events as jev
import ../journal/log

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

  ChildFactory* = proc(): Future[void] {.closure, gcsafe, raises: [].}
    ## Must not raise synchronously and must be gcsafe. An `{.async.}`
    ## proc call site satisfies this — the proc body's raises are
    ## encoded in the returned Future, not at the call.

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

  Supervisor* = ref object
    strategy*: Strategy
    maxRestarts*: int
    within*: Duration
    children: seq[ChildState]

  SupervisorEscalation* = object of CatchableError
    childName*: string

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

proc run*(s: Supervisor) {.async: (raises: [CatchableError]).} =
  ## Run the supervisor loop. Returns when every child has reached a
  ## terminal state (lcTemporary done, or lcTransient exited cleanly,
  ## or rate limit escalated). Cancellation propagates: cancelling the
  ## supervisor task cancels every child.
  ##
  ## `{.task.}` is required: `spawn` reads `currentScope` to parent
  ## the child mount, and every `journalEvent` inside the loop reads
  ## `currentScope.taskId` / `lastEventId`. Both must survive the
  ## `await race(futs)` and the cascade-drain awaits.

  # Start each child once.
  for child in s.children:
    child.mount = spawn child.spec.factory()

  while s.children.len > 0:
    # Wait for any child to finish.
    var futs: seq[FutureBase] = @[]
    for child in s.children:
      futs.add child.mount.future.FutureBase
    let winner = await race(futs)

    var idx = -1
    for i, child in s.children:
      if child.mount.future.FutureBase == winner: idx = i; break
    if idx < 0: continue
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

      target.mount = spawn target.spec.factory()

# --- Topology introspection ----------------------------------------------

type
  TopologyNode* = object
    name*: string
    lifecycle*: Lifecycle
    running*: bool
    taskId*: jev.TaskId
    restartCount*: int

proc topology*(s: Supervisor): seq[TopologyNode] =
  ## Snapshot of the supervisor's children — name, lifecycle, whether
  ## the current mount is still running, the latest taskId, and a
  ## count of restarts in the active sliding window. Useful for
  ## devtools panels and external monitoring (metrics, logs).
  for child in s.children:
    var node = TopologyNode(
      name: child.spec.name,
      lifecycle: child.spec.lifecycle,
      restartCount: child.restartTimes.len)
    if child.mount != nil:
      node.running = not child.mount.future.finished
      if child.mount.scope != nil:
        node.taskId = child.mount.scope.taskId
    result.add node

# --- Declarative supervisor: block ---------------------------------------

macro supervisor*(name: untyped, body: untyped): untyped =
  ## Declarative supervisor topology:
  ##
  ##   supervisor appSup:
  ##     maxRestarts = 5
  ##     within = 10.seconds
  ##     strategy = ssOneForOne
  ##
  ##     child("heartbeat", lcPermanent, heartbeatTask)
  ##     child("agent",     lcTransient, agentLoop)
  ##
  ##   await appSup.run()                # later
  ##
  ## Config assignments (`name = value`) become named arguments on
  ## `newSupervisor()`. `child(...)` calls become `addChild` calls.
  expectKind(body, nnkStmtList)

  const KnownConfigKeys = ["strategy", "maxRestarts", "within"]

  var supInit = newCall(bindSym"newSupervisor")
  var addCalls: seq[NimNode] = @[]

  for stmt in body:
    case stmt.kind
    of nnkAsgn:
      let key = stmt[0]
      let val = stmt[1]
      # Normalize via strVal: hygiene may wrap `key` as nnkSym (or
      # nnkOpenSymChoice) when `supervisor:` is invoked inside a
      # template. `strVal` returns the base name for any ident-like
      # node, but bare `$node` on a gensym'd nnkSym would include
      # the mangle suffix.
      let keyName =
        if key.kind in {nnkIdent, nnkSym, nnkOpenSymChoice}:
          key.strVal
        else:
          ""
      if keyName notin KnownConfigKeys:
        error("supervisor: unknown config key `" & key.repr &
              "` (expected one of " & $KnownConfigKeys & ")", key)
      # Rebuild the named-argument key as a fresh ident — Nim's
      # named-arg call form requires nnkIdent here; passing an
      # nnkSym would error during semantic check.
      supInit.add newTree(nnkExprEqExpr, ident(keyName), val)
    of nnkCall:
      if stmt[0].eqIdent("child"):
        let addCall = newCall(newDotExpr(name, ident("addChild")))
        for i in 1 ..< stmt.len:
          addCall.add stmt[i]
        addCalls.add addCall
      else:
        error("supervisor: unknown statement `" & stmt.repr &
              "` (expected config assignment or child(...) call)", stmt)
    else:
      error("supervisor: body must be config assignments or " &
            "child(name, lifecycle, factory) calls", stmt)

  result = newStmtList()
  result.add newLetStmt(name, supInit)
  for ac in addCalls: result.add ac
