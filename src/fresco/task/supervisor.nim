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
import ./cls
import ../reactive/scope
import ../journal/events as jev
import ../journal/log

type
  Lifecycle* = enum
    lcPermanent     ## always restart, success or failure
    lcTransient     ## restart only on abnormal exit (failure or cancel)
    lcTemporary     ## never restart

  Strategy* = enum
    sOneForOne      ## restart only the failing child
    sOneForAll      ## any failure → cancel all siblings, restart all
    sRestForOne     ## any failure → cancel this child + all *later* siblings
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
    ## from `ekStateWrite` events. Restoration happens out of band —
    ## the factory will still be called fresh after the handler.

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

proc newSupervisor*(strategy = sOneForOne,
                    maxRestarts = 5,
                    within = 10.seconds): Supervisor =
  Supervisor(
    strategy: strategy,
    maxRestarts: maxRestarts,
    within: within)

proc addChild*(s: Supervisor, name: string,
               lifecycle: Lifecycle, factory: ChildFactory,
               onError: ErrorPolicy = nil,
               onRestart: RestartHandler = nil) =
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
  while times.len > 0 and now - times[0] > window:
    times.delete(0)

proc run*(s: Supervisor) {.task, async: (raises: [CatchableError]).} =
  ## Run the supervisor loop. Returns when every child has reached a
  ## terminal state (lcTemporary done, or lcTransient exited cleanly,
  ## or rate limit escalated). Cancellation propagates: cancelling the
  ## supervisor task cancels every child.

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
    var policyAction = eaRestart    # sentinel; only used if policy fires
    var policyFired = false
    if failed and child.spec.onError != nil:
      let err = child.mount.future.error
      if err != nil:
        try:
          policyAction = child.spec.onError(err)
          policyFired = true
        except Exception:
          discard

    if policyFired and policyAction == eaTerminate:
      if globalJournal != nil:
        let tid = if currentScope != nil: currentScope.taskId else: jev.RootTask
        let p   = if currentScope != nil: currentScope.lastEventId else: jev.NoEvent
        try:
          let id = globalJournal.logSupervisorTerminate(tid, p, child.spec.name)
          if currentScope != nil: currentScope.lastEventId = id
        except CatchableError: discard
      s.children.delete(idx)
      continue

    if policyFired and policyAction == eaEscalate:
      var err = newException(SupervisorEscalation,
        "child '" & child.spec.name & "' onError requested escalation")
      err.childName = child.spec.name
      if globalJournal != nil:
        let tid = if currentScope != nil: currentScope.taskId else: jev.RootTask
        let p   = if currentScope != nil: currentScope.lastEventId else: jev.NoEvent
        try:
          let id = globalJournal.logSupervisorEscalate(tid, p,
            child.spec.name, err.msg)
          if currentScope != nil: currentScope.lastEventId = id
        except CatchableError: discard
      for c in s.children:
        if not c.mount.future.finished: c.mount.cancel()
      raise err

    if not shouldRestart(child.spec.lifecycle, failed):
      if globalJournal != nil:
        let tid = if currentScope != nil: currentScope.taskId else: jev.RootTask
        let p   = if currentScope != nil: currentScope.lastEventId else: jev.NoEvent
        try:
          let id = globalJournal.logSupervisorTerminate(tid, p, child.spec.name)
          if currentScope != nil: currentScope.lastEventId = id
        except CatchableError: discard
      s.children.delete(idx)
      continue

    let now = Moment.now()
    child.restartTimes.add now
    trimWindow(child.restartTimes, now, s.within)
    if child.restartTimes.len > s.maxRestarts:
      var err = newException(SupervisorEscalation,
        "child '" & child.spec.name & "' exceeded " &
        $s.maxRestarts & " restarts in " & $s.within)
      err.childName = child.spec.name
      if globalJournal != nil:
        let tid = if currentScope != nil: currentScope.taskId else: jev.RootTask
        let p   = if currentScope != nil: currentScope.lastEventId else: jev.NoEvent
        try:
          let id = globalJournal.logSupervisorEscalate(tid, p,
            child.spec.name, err.msg)
          if currentScope != nil: currentScope.lastEventId = id
        except CatchableError: discard
      for c in s.children:
        if not c.mount.future.finished: c.mount.cancel()
      raise err

    # Determine the cascade group based on supervisor strategy.
    #   sOneForOne:  just the failing child.
    #   sRestForOne: failing child + every child declared after it.
    #   sOneForAll:  every child.
    var cascade: seq[int] = @[]
    case s.strategy
    of sOneForOne:
      cascade.add idx
    of sRestForOne:
      for i in idx ..< s.children.len: cascade.add i
    of sOneForAll:
      for i in 0 ..< s.children.len: cascade.add i

    # Cancel siblings in the cascade (the triggering child is already
    # finished). Then wait for cancellation cascades to settle.
    for i in cascade:
      if i != idx and not s.children[i].mount.future.finished:
        s.children[i].mount.cancel()
    for i in cascade:
      if i != idx:
        try: await s.children[i].mount.future
        except CatchableError: discard

    # Re-spawn every cascaded child. Logging + onRestart handlers fire
    # per child so the journal records the full cascade.
    for i in cascade:
      let target = s.children[i]
      if globalJournal != nil:
        let tid = if currentScope != nil: currentScope.taskId else: jev.RootTask
        let p   = if currentScope != nil: currentScope.lastEventId else: jev.NoEvent
        try:
          let id = globalJournal.logSupervisorRestart(tid, p,
            target.spec.name, target.restartTimes.len)
          if currentScope != nil: currentScope.lastEventId = id
        except Exception: discard

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
  ##     strategy = sOneForOne
  ##
  ##     child("heartbeat", lcPermanent, heartbeatTask)
  ##     child("agent",     lcTransient, agentLoop)
  ##
  ##   await appSup.run()                # later
  ##
  ## Config assignments (`name = value`) become named arguments on
  ## `newSupervisor()`. `child(...)` calls become `addChild` calls.
  expectKind(body, nnkStmtList)

  var supInit = newCall(bindSym"newSupervisor")
  var addCalls: seq[NimNode] = @[]

  for stmt in body:
    case stmt.kind
    of nnkAsgn:
      let key = stmt[0]
      let val = stmt[1]
      supInit.add newTree(nnkExprEqExpr, key, val)
    of nnkCall:
      if stmt[0].kind == nnkIdent and $stmt[0] == "child":
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
