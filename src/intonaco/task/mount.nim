## Reactive conditional mount: `mountWhen(cond): body`.
##
## While `cond` evaluates truthy, the body (which produces a Mount —
## typically `spawn child()`) is kept alive. When `cond` flips false,
## the current Mount is cancelled. When it flips true again, a fresh
## Mount is spawned. On scope dispose, the active Mount is cancelled
## together with the rest of the cleanup chain.
##
##   mountWhen(showHelp()):
##     spawn helpOverlay()
##
##   mountWhen(active() and depth() < 10):
##     spawn worker()

import chronos/contextvars
import intonaco/reactive/scope
import intonaco/reactive/signal
import ./core

template mountWhen*(cond: untyped, body: untyped): untyped =
  ## Reactive conditional mount. `cond` is re-evaluated whenever any
  ## signal it reads changes; `body` must yield a Mount when the
  ## condition is true.
  ##
  ## Also exposed as `mount(cond): body` — same semantics, terser
  ## DSL form. Pick whichever reads better at the call site.
  ##
  ## The effect body fires from `notify`, not from any task — the
  ## dispatcher's `currentScope` at that point is whatever the last
  ## coroutine left behind (often nil). We capture the registering
  ## scope's context here and restore it around the effect body so
  ## `spawn`s inside `body` parent to the right place and journal
  ## events attribute to the right task.
  let mountWhenCtx = currentContext()
  var currentMount: Mount = nil
  createEffect proc() =
    withContext(mountWhenCtx):
      let shouldMount = cond
      if shouldMount:
        if currentMount == nil or currentMount.future.finished:
          currentMount = body
      else:
        if currentMount != nil and not currentMount.future.finished:
          currentMount.cancel()
          currentMount = nil
  onCleanup proc() =
    if currentMount != nil and not currentMount.future.finished:
      currentMount.cancel()
      currentMount = nil

template mount*(cond: untyped, body: untyped): untyped =
  ## DSL-form alias for `mountWhen`. `mount(cond): body` reads as
  ## "mount this child when cond is true."
  mountWhen(cond, body)
