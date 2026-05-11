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

import std/sequtils
import chronos
import ./core

type
  Lifecycle* = enum
    lcPermanent     ## always restart, success or failure
    lcTransient     ## restart only on abnormal exit (failure or cancel)
    lcTemporary     ## never restart

  Strategy* = enum
    sOneForOne      ## restart only the failing child
    # sOneForAll  / sRestForOne land in v2.3

  ChildFactory* = proc(): Future[void] {.closure, gcsafe, raises: [].}
    ## Must not raise synchronously and must be gcsafe. An `{.async.}`
    ## proc call site satisfies this — the proc body's raises are
    ## encoded in the returned Future, not at the call.

  ChildSpec* = object
    name*: string
    lifecycle*: Lifecycle
    factory*: ChildFactory

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
               lifecycle: Lifecycle, factory: ChildFactory) =
  s.children.add ChildState(
    spec: ChildSpec(name: name, lifecycle: lifecycle, factory: factory))

proc shouldRestart(lifecycle: Lifecycle, failed: bool): bool =
  case lifecycle
  of lcPermanent: true
  of lcTransient: failed
  of lcTemporary: false

proc trimWindow(times: var seq[Moment], now: Moment, window: Duration) =
  while times.len > 0 and now - times[0] > window:
    times.delete(0)

proc run*(s: Supervisor) {.async: (raises: [CatchableError]).} =
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

    if not shouldRestart(child.spec.lifecycle, failed):
      s.children.del idx
      continue

    let now = Moment.now()
    child.restartTimes.add now
    trimWindow(child.restartTimes, now, s.within)
    if child.restartTimes.len > s.maxRestarts:
      var err = newException(SupervisorEscalation,
        "child '" & child.spec.name & "' exceeded " &
        $s.maxRestarts & " restarts in " & $s.within)
      err.childName = child.spec.name
      for c in s.children:
        if not c.mount.future.finished: c.mount.cancel()
      raise err

    child.mount = spawn child.spec.factory()
