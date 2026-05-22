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
import intonaco/reactive/scope
import intonaco/journal/events
import intonaco/journal/log
import ./types

export types  # Mount, MountCollector, parallelCollector — public surface

proc cancel*(m: Mount) {.gcsafe, raises: [].} =
  ## Cancel the task. Idempotent. Triggers scope dispose via the
  ## future-completion callback. Swallows any exception from cleanup
  ## closures so cancel is safe to call from callback bodies.
  ##
  ## **Sync/async asymmetry:** `cancel` returns immediately. The scope
  ## is disposed synchronously (cleanup closures run before this proc
  ## returns), but the child future's cancellation request is async
  ## (`cancelSoon`). A caller that needs the child to be fully halted
  ## before proceeding must `await m.wait()` after cancel.
  if m == nil: return
  if not m.future.finished:
    m.future.cancelSoon()
  {.cast(gcsafe).}:
    try: dispose(m.scope)
    except Exception: discard   # dispose's cleanup closures untyped-raise

proc wait*(m: Mount): Future[void] {.async: (raises: [CancelledError, CatchableError]).} =
  ## Wait for the task to complete. Propagates the task's exception
  ## (if any) into the caller. Named `wait` rather than `await` to
  ## avoid colliding with chronos's `await` template at call sites; use
  ## as `await m.wait()`.
  if m == nil: return
  await m.future

proc finished*(m: Mount): bool =
  m != nil and m.future.finished

proc wireLifecycle(m: Mount) =
  ## Install both directions of the scope ↔ future bond plus the
  ## journal completion / failure / cancellation hooks.
  ##
  ## The future-completion callback runs from the chronos dispatcher,
  ## not from within any task's body — `currentScope` is whatever the
  ## dispatcher left there (typically nil). All journal writes here
  ## explicitly use `captured.scope` so they're correctly attributed
  ## regardless. Any `dispose`-triggered onCleanup closures that
  ## themselves want a scope-relative side effect (rare) must use
  ## `withScope(captured.scope): ...` internally.
  let captured = m
  # Direction 1: scope dispose → cancel future.
  withScope(m.scope):
    onCleanup proc() =
      if not captured.future.finished:
        captured.future.cancelSoon()
  # Direction 2: future complete / cancel → log + dispose scope.
  m.future.addCallback proc(udata: pointer) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      # Journal write uses `journalEventOnScope` so attribution is the
      # task's own scope (`captured.scope`), not whatever
      # `currentScope` the dispatcher left behind. The template
      # internally swallows CatchableError (the journal contract);
      # we wrap only the `dispose` call in a broader Exception catch
      # since cleanup closures can untyped-raise.
      journalEventOnScope(captured.scope):
        if captured.future.cancelled:
          jrnl.logTaskCancelled(taskTid, parentEvt, "")
        elif captured.future.failed:
          let e = captured.future.error
          jrnl.logTaskFailed(taskTid, parentEvt,
            if e == nil: "" else: e.msg,
            if e == nil: "" else: $e.name)
        else:
          jrnl.logTaskCompleted(taskTid, parentEvt)
      if not captured.scope.disposed:
        try: dispose(captured.scope)
        except Exception: discard   # dispose's cleanup closures untyped-raise

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
  ##
  ## **`parallelCollector` isolation:** the collector captures *direct*
  ## spawns of the enclosing `parallel:` block, not the spawns a child
  ## task makes internally. Without isolation, `parallel: spawn
  ## sup.run()` would leak the supervisor's own children into the
  ## outer parallel group (sup.run's synchronous startup loop runs
  ## with the inherited threadvar). The fix clears `parallelCollector`
  ## while the child task's body executes synchronously up to its
  ## first await; after the call returns we restore the parent value
  ## and register this Mount with it.
  block:
    let childScope = newScope(currentScope)
    childScope.taskId = TaskId.fresh()
    # Direct logTaskSpawned write rather than `journalEvent` — this
    # site must advance lastEventId on BOTH the new childScope (so
    # the child's first event chains from its own spawn) AND the
    # parent's currentScope (so the parent's causal chain advances
    # to the child's birth event). journalEvent only writes to
    # currentScope.
    #
    # Wrapped in try/except CatchableError: discard so a journal
    # write failure (e.g., PersistentJournal disk error) doesn't
    # propagate out of `spawn`. Matches the swallow contract every
    # other journal call site honours.
    if globalJournal != nil:
      try:
        let parent =
          if currentScope != nil: currentScope.lastEventId else: NoEvent
        let id = globalJournal.logTaskSpawned(
          childScope.taskId, parent, astToStr(call), "")
        childScope.lastEventId = id
        if currentScope != nil:
          currentScope.lastEventId = id
      except CatchableError: discard
    var fut: Future[void]
    # Child task body must not see parent's parallelCollector — otherwise
    # spawns the child makes internally would leak into the parent's
    # parallel: group. Binding nil for the duration of `call` isolates
    # the child's synchronous startup.
    withParallelCollector(nil):
      withScope(childScope):
        fut = call
    let m = Mount(scope: childScope, future: fut, name: astToStr(call))
    # Register with the parallel collector BEFORE wiring lifecycle.
    # `wireLifecycle.addCallback` fires synchronously when the future
    # is already finished (a fully-sync async body), and the callback
    # disposes the scope. If we wired lifecycle first, a same-tick-
    # completing task would be disposed before we got to add it to
    # the collector — silently dropped from the parallel join group.
    if parallelCollector != nil:
      parallelCollector.mounts.add m
    wireLifecycle(m)
    m
