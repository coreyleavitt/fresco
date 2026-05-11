## Task primitive: async coroutine + reactive scope, joined by a Mount handle.
##
## A task is an async chronos proc you `spawn`. Spawning opens a fresh
## reactive scope as a child of the current scope, runs the proc inside
## that scope (so signal/effect declarations bind to it), and hands back
## a `Mount` that owns both the scope and the resulting Future.
##
## Lifecycle is bidirectional:
##   - Disposing the scope cancels the Future (cleanup propagates down).
##   - Future completion / cancellation disposes the scope (cleanup runs
##     after the work is done).
##
## Parent → child cancellation cascades because spawning inside a parent
## scope makes the child's scope a child of the parent's; disposing
## the parent disposes its children, which cancels their Futures.

import chronos
import ../reactive/scope
import ../journal/events
import ../journal/log

type
  Mount* = ref object
    scope*: Scope
    future*: Future[void]

var parallelCollector* {.threadvar.}: ptr seq[Mount]
  ## When set, any `spawn` adds its Mount to the pointed-to seq so a
  ## `parallel:` block can await them as a group. Lifetime-scoped by
  ## the `parallel` template; do not touch directly.

proc cancel*(m: Mount) {.gcsafe, raises: [].} =
  ## Cancel the task. Idempotent. Triggers scope dispose via the
  ## future-completion callback. Swallows any exception from cleanup
  ## closures so cancel is safe to call from callback bodies.
  if m == nil: return
  if not m.future.finished:
    m.future.cancelSoon()
  {.cast(gcsafe).}:
    try: dispose(m.scope)
    except Exception: discard

proc wait*(m: Mount): Future[void] {.async: (raises: [CancelledError, CatchableError]).} =
  ## Wait for the task to complete. Propagates the task's exception
  ## (if any) into the caller. Named `wait` rather than `await` to
  ## avoid colliding with chronos's `await` macro at call sites; use
  ## as `await m.wait()`.
  if m == nil: return
  await m.future

proc finished*(m: Mount): bool =
  m != nil and m.future.finished

proc wireLifecycle(m: Mount) =
  ## Install both directions of the scope ↔ future bond plus the
  ## journal completion / failure / cancellation hooks.
  let captured = m
  # Direction 1: scope dispose → cancel future.
  withScope(m.scope):
    onCleanup proc() =
      if not captured.future.finished:
        captured.future.cancelSoon()
  # Direction 2: future complete / cancel → log + dispose scope.
  m.future.addCallback proc(udata: pointer) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      try:
        if globalJournal != nil:
          let parent = captured.scope.lastEventId
          let tid    = captured.scope.taskId
          let id =
            if captured.future.cancelled:
              globalJournal.logTaskCancelled(tid, parent, "")
            elif captured.future.failed:
              let e = captured.future.error
              globalJournal.logTaskFailed(tid, parent,
                if e == nil: "" else: e.msg,
                if e == nil: "" else: $e.name)
            else:
              globalJournal.logTaskCompleted(tid, parent)
          captured.scope.lastEventId = id
        if not captured.scope.disposed:
          dispose(captured.scope)
      except Exception:
        discard

template spawnRetry*(retries: int, call: untyped): Mount =
  ## Retry the spawned task up to `retries` times on failure. Each
  ## retry re-evaluates `call`, so the expression must be repeatable
  ## (typically a plain proc invocation). Cancellation propagates and
  ## stops further retries.
  block:
    proc retryThunk(): Future[void] {.async.} =
      var attempts = 0
      while true:
        inc attempts
        try:
          let f = call
          await f
          return
        except CancelledError:
          raise
        except CatchableError:
          if attempts > retries: raise
    spawn retryThunk()

template spawnCatch*(call: untyped): Mount =
  ## Swallow any non-cancellation failure of the spawned task and
  ## complete the Mount successfully. Useful when the failure is
  ## already handled out-of-band (logging, signal mutation) and the
  ## supervisor shouldn't see it.
  block:
    proc catchThunk(): Future[void] {.async.} =
      try:
        let f = call
        await f
      except CancelledError:
        raise
      except CatchableError:
        discard
    spawn catchThunk()

template spawn*(call: untyped): Mount =
  ## Open a child scope, run the async `call` inside it, return a Mount.
  ## The call must be an invocation of an `{.async.}` proc returning
  ## `Future[void]`. If we're inside a `parallel:` block, the Mount is
  ## also added to the block's collector for group-await.
  block:
    let childScope = newScope(currentScope)
    childScope.taskId = TaskId.fresh()
    if globalJournal != nil:
      let parent =
        if currentScope != nil: currentScope.lastEventId else: NoEvent
      let id = globalJournal.logTaskSpawned(
        childScope.taskId, parent, astToStr(call), "")
      childScope.lastEventId = id
      if currentScope != nil:
        currentScope.lastEventId = id
    var fut: Future[void]
    withScope(childScope):
      fut = call
    let m = Mount(scope: childScope, future: fut)
    wireLifecycle(m)
    if parallelCollector != nil:
      parallelCollector[].add m
    m
