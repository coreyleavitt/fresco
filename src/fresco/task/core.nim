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

type
  Mount* = ref object
    scope*: Scope
    future*: Future[void]

proc cancel*(m: Mount) {.gcsafe.} =
  ## Cancel the task. Idempotent. Triggers scope dispose via the
  ## future-completion callback.
  if m == nil: return
  if not m.future.finished:
    m.future.cancelSoon()
  {.cast(gcsafe).}:
    dispose(m.scope)

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
  ## Install both directions of the scope ↔ future bond.
  let captured = m
  # Direction 1: scope dispose → cancel future.
  withScope(m.scope):
    onCleanup proc() =
      if not captured.future.finished:
        captured.future.cancelSoon()
  # Direction 2: future complete / cancel → dispose scope.
  m.future.addCallback proc(udata: pointer) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      try:
        if not captured.scope.disposed:
          dispose(captured.scope)
      except Exception:
        discard

template spawn*(call: untyped): Mount =
  ## Open a child scope, run the async `call` inside it, return a Mount.
  ## The call must be an invocation of an `{.async.}` proc returning
  ## `Future[void]`.
  block:
    let childScope = newScope(currentScope)
    var fut: Future[void]
    withScope(childScope):
      fut = call
    let m = Mount(scope: childScope, future: fut)
    wireLifecycle(m)
    m
