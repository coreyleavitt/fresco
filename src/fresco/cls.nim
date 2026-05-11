## Continuation-local storage — the fresco context substrate.
##
## fresco depends on three dynamically-scoped variables to wire
## reactive owners, journal attribution, and structured-concurrency
## collectors:
##
##   `currentScope`        — who owns the cleanup chain and journal task id
##   `currentSpeculative`  — the active speculative frame for revert-on-rollback
##   `parallelCollector`   — the seq into which `spawn` reports new Mounts
##
## All three are thread-locals. Chronos doesn't restore thread-locals
## across coroutine suspensions, so a bare `await` inside any task body
## silently strips them: after resume, signal writes attribute to the
## wrong task, spawns parent to the wrong scope, and reverts land in
## someone else's speculative frame.
##
## (`currentComputation` is also a threadvar but deliberately *not*
## continuation-local. It's set by `createEffect`/`tracked:` for the
## synchronous duration of a body and never meant to outlive an
## `await` — effect bodies aren't expected to suspend. Including it
## here would clobber the dep-tracking computation an outer effect
## had just set up.)
##
## **CLS substrate.** The unit of dynamic binding should be the
## continuation, not the OS thread — the same insight Python
## `contextvars`, .NET `AsyncLocal<T>`, Kotlin `CoroutineContext`,
## Scheme `parameterize` all converged on. We emulate it by injecting,
## around every `await` in a proc body, a save of the three threadvars
## into a closure-local before suspension and a restore after resume.
## Locals survive `await` (chronos's state-machine transform captures
## them in the iterator's environment), so the threadvars are correctly
## reinstated whenever the coroutine resumes — without the user
## thinking about it.
##
## Usage:
##
##   proc handleKey() {.task, async.} =
##     await stream.nextKey()
##     count := count() + 1   # currentScope correct here
##
## Put `task` *before* `async` in the pragma list — pragmas run
## left-to-right, and `task` must rewrite the body before chronos
## transforms it into a state machine.
##
## For one-off use outside a `{.task.}` proc, call `withContext` around
## a block that needs the three threadvars to match a previously
## captured `TaskContext`.

import std/macros
import ./reactive/scope
import ./reactive/speculative
import ./task/types   # Mount, MountCollector, parallelCollector — types only

type
  TaskContext* = object
    ## Snapshot of fresco's three continuation-local runtime slots.
    ## Cheap to capture (pointer-sized fields) and trivially copyable.
    scope*: Scope
    speculative*: SpeculativeScope
    parallelCollector*: MountCollector

proc captureContext*(): TaskContext {.gcsafe.} =
  {.cast(gcsafe).}:
    TaskContext(
      scope: currentScope,
      speculative: currentSpeculative,
      parallelCollector: parallelCollector)

proc restoreContext*(ctx: TaskContext) {.gcsafe.} =
  {.cast(gcsafe).}:
    currentScope = ctx.scope
    currentSpeculative = ctx.speculative
    parallelCollector = ctx.parallelCollector

macro taskAwait*(call: untyped): untyped =
  ## Wrap a single `await` with CLS save/restore. Use this when a
  ## macro or template emits an `await` — those emissions happen
  ## AFTER the `{.task.}` pragma has walked the enclosing proc body,
  ## so task's rewriter never sees them. The `parallel:` template
  ## and the `receive:` macro use this internally.
  ##
  ## **Do not use inside a `{.task.}` proc.** Bare `await X` there is
  ## already rewritten by the pragma. Calling `taskAwait` would
  ## produce harmless-but-wasteful double-wrapping.
  let ctxSym = genSym(nskLet, "frescoCtx")
  result = quote do:
    block:
      let `ctxSym` = captureContext()
      try:
        await `call`
      finally:
        restoreContext(`ctxSym`)

template withContext*(ctx: TaskContext, body: untyped) =
  ## Run `body` with the three fresco threadvars set from `ctx`. Restores
  ## the previously-current context on every exit path. Useful in
  ## callback-style code (effect bodies, input filters) that fires from
  ## the dispatcher with whatever scope happened to be current — wrap
  ## the body in `withContext(savedCtx):` to attribute it to the right
  ## owner.
  let prevCtx = captureContext()
  restoreContext(ctx)
  try:
    body
  finally:
    restoreContext(prevCtx)

macro task*(prc: untyped): untyped =
  ## Pragma: rewrite every `await` in the proc body to inline
  ## save/restore of the three fresco threadvars. Compose with
  ## `{.async.}` (or `{.async: (raises: [...]).}`) — *put `task`
  ## first*:
  ##
  ##   proc foo() {.task, async.} = await bar()
  ##   proc sup() {.task, async: (raises: [CatchableError]).} = ...
  ##
  ## The rewrite is purely structural: any `await X` (whether
  ## `nnkCommand` or `nnkCall` form) is replaced with
  ##
  ##   block:
  ##     let __frescoCtx = captureContext()
  ##     try:
  ##       await X
  ##     finally:
  ##       restoreContext(__frescoCtx)
  ##
  ## `try`-as-expression carries the awaited value through, so the
  ## rewrite is transparent for both `await voidFut` and
  ## `let x = await valFut`. The `finally` ensures context is restored
  ## on CancelledError or any other exception path.
  expectKind(prc, {nnkProcDef, nnkLambda})

  # Order check: `task` is meaningful only when chronos's `async`
  # hasn't yet transformed the body. Nim processes pragmas left-to-
  # right and strips each one before invoking its macro, so by the
  # time `task` runs, the remaining pragmas are visible at prc[4].
  # If `async` isn't among them, the user either combined them in
  # the wrong order (`{.async, task.}`) or applied `task` without
  # `async` (which is meaningless — nothing to wrap).
  var hasAsync = false
  if prc[4].kind != nnkEmpty:
    for p in prc[4]:
      let head = if p.kind == nnkExprColonExpr: p[0] else: p
      # `eqIdent` matches nnkIdent, nnkSym, and nnkOpenSymChoice —
      # necessary because inside a template, hygiene may wrap the
      # pragma ident as a symbol or an open-sym-choice.
      if head.eqIdent("async"):
        hasAsync = true
        break
  if not hasAsync:
    error("task: must be combined with `{.async.}` and must appear " &
          "*before* it in the pragma list. Nim processes pragmas " &
          "left-to-right; if `async` runs first, it state-machines " &
          "the body and `task` has nothing to rewrite. Use " &
          "`{.task, async.}` (not `{.async, task.}`).", prc)

  proc rewrite(n: NimNode): NimNode =
    # eqIdent matches nnkIdent, nnkSym, and nnkOpenSymChoice — needed
    # because if a `{.task, async.}` proc is defined inside a template,
    # hygiene may wrap `await` as a symbol. The same generalization the
    # pragma-order check above does for `async`.
    if n.kind in {nnkCommand, nnkCall} and n.len >= 2 and
       n[0].eqIdent("await"):
      let inner = rewrite(n[1])
      let ctxSym = genSym(nskLet, "frescoCtx")
      result = quote do:
        block:
          let `ctxSym` = captureContext()
          try:
            await `inner`
          finally:
            restoreContext(`ctxSym`)
    else:
      result = copyNimNode(n)
      for child in n:
        result.add rewrite(child)

  prc.body = rewrite(prc.body)
  result = prc
