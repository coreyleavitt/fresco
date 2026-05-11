## Reactive owner scopes.
##
## A Scope owns a set of cleanup callbacks and child scopes. Disposing
## a scope cascades: children dispose first (LIFO), then this scope's
## cleanups run in reverse registration order. After dispose() the
## scope is permanently dead; further operations are no-ops.
##
## `currentScope` is the dynamically-scoped owner that signals,
## effects, and child tasks attach themselves to. Use `withScope` to
## install a scope as current for a block; use `createRoot` for the
## common case of opening a fresh root.

type
  Scope* = ref object
    parent*: Scope
    children: seq[Scope]
    cleanups: seq[proc() {.closure.}]
    disposed*: bool

var currentScope* {.threadvar.}: Scope

proc newScope*(parent: Scope = nil): Scope =
  result = Scope(parent: parent)
  if parent != nil:
    parent.children.add result

proc onCleanup*(body: proc() {.closure.}) =
  ## Register `body` to run when the current scope is disposed.
  ## No-op outside any scope.
  if currentScope == nil or currentScope.disposed: return
  currentScope.cleanups.add body

proc dispose*(s: Scope) =
  ## Idempotent. Dispose children first (LIFO), then run cleanups
  ## (reverse registration order), then detach from parent.
  if s == nil or s.disposed: return
  s.disposed = true
  for i in countdown(s.children.high, 0):
    dispose(s.children[i])
  s.children.setLen(0)
  for i in countdown(s.cleanups.high, 0):
    s.cleanups[i]()
  s.cleanups.setLen(0)
  if s.parent != nil:
    let idx = s.parent.children.find(s)
    if idx >= 0: s.parent.children.del(idx)

template withScope*(scope: Scope, body: untyped) =
  ## Install `scope` as `currentScope` for the duration of `body`.
  ## Restores the previous current on every exit path.
  let prevScope = currentScope
  currentScope = scope
  try:
    body
  finally:
    currentScope = prevScope

template createRoot*(body: untyped): Scope =
  ## Open a fresh root scope, run `body` inside, and return the scope
  ## so the caller can `dispose` it later.
  let rootScope = newScope()
  withScope(rootScope):
    body
  rootScope
