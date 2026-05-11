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

import ../reactive/scope
import ../reactive/signal
import ./core

template mountWhen*(cond: untyped, body: untyped): untyped =
  ## Reactive conditional mount. `cond` is re-evaluated whenever any
  ## signal it reads changes; `body` must yield a Mount when the
  ## condition is true.
  var currentMount: Mount = nil
  createEffect proc() =
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
