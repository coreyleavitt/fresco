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
  ## This is a thread-local L1 cache. Chronos doesn't restore
  ## thread-locals across coroutine suspensions on its own, so the
  ## fresco continuation-local substrate (`fresco/task/cls`) handles
  ## save/restore around every await. Use the `{.task.}` pragma on
  ## any async proc that needs `currentScope` to survive its awaits:
  ##
  ##     proc myTask() {.task, async.} =
  ##       await something()
  ##       signal.set(x)         # currentScope is preserved
  ##
  ## For callback-style code (effect bodies, input filters) that fires
  ## from the dispatcher with whatever scope happens to be current,
  ## capture a `TaskContext` at registration and wrap the callback
  ## body in `withContext(ctx):` to attribute it to the right owner.
  ## `mountWhen` and `hotkey` do this internally.

proc newScope*(parent: Scope = nil): Scope =
  ## Construct a fresh Scope, optionally parented. Disposal cascades
  ## from parent to children. `createRoot` is the higher-level form
  ## that also installs the new scope as `currentScope` for a body.
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
    # Snapshot the children seq before iterating. A cleanup that
    # disposes a *sibling* (via a captured reference) would otherwise
    # mutate `s.children` mid-loop and corrupt the index.
    let childSnap = s.children
    s.children.setLen(0)
    for i in countdown(childSnap.high, 0):
      dispose(childSnap[i])
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
