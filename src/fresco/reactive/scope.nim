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

import ../journal/events

type
  ProviderEntry* = object
    typeKey*: pointer
      ## Unique identity per type. Two `Config` types in different
      ## modules have distinct keys even though `$T` would produce
      ## the same string. See `context.typeMarker`.
    fetch*: proc(): pointer {.closure.}
      ## Closure that returns the stored value as a pointer. The
      ## closure captures the original ref, which keeps it alive
      ## as long as this entry exists.

  Scope* = ref object
    parent*: Scope
    children: seq[Scope]
    cleanups: seq[proc() {.closure.}]
    providers*: seq[ProviderEntry]
    taskId*: TaskId
      ## Journal task identity. RootTask (0) for scopes created
      ## outside any spawn. Spawn assigns a fresh TaskId per child.
    lastEventId*: EventId
      ## The most recent event this task emitted into the journal.
      ## Used as the parentId for subsequent events from this scope.
    disposed*: bool

var currentScope* {.threadvar.}: Scope
  ## Dynamically-scoped owner that signals, effects, and child tasks
  ## attach themselves to.
  ##
  ## **Constraint:** this is a thread-local — it's only reliable for
  ## synchronous code. Chronos doesn't restore thread-locals across
  ## coroutine suspension, so after a task awaits, `currentScope` is
  ## whatever the last-running coroutine left behind (typically `nil`).
  ## Code that needs the task's scope after an await should capture
  ## the scope at task entry and re-bind explicitly:
  ##
  ##     proc myTask() {.async.} =
  ##       let myScope = currentScope         # capture once
  ##       # ... work that may await ...
  ##       withScope(myScope):                # re-bind for any
  ##         signal.set(x)                    # context-sensitive code
  ##
  ## v3 fix tracked at github issue #37: chronos async-macro extension
  ## that saves/restores per-coroutine context at every suspension.

proc newScope*(parent: Scope = nil): Scope =
  result = Scope(parent: parent)
  if parent != nil:
    parent.children.add result

proc onCleanup*(body: proc() {.closure.}) {.gcsafe.} =
  ## Register `body` to run when the current scope is disposed.
  ## No-op outside any scope.
  {.cast(gcsafe).}:
    if currentScope == nil or currentScope.disposed: return
    currentScope.cleanups.add body

proc dispose*(s: Scope) {.gcsafe.} =
  ## Idempotent. Dispose children first (LIFO), then run cleanups
  ## (reverse registration order), then detach from parent.
  if s == nil or s.disposed: return
  s.disposed = true
  {.cast(gcsafe).}:
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
