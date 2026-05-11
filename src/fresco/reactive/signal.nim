## Signals + effects + computed values with runtime dep tracking.
##
## v2.0 implementation: Solid-flavored eager propagation. A signal
## write synchronously runs every registered observer. The compile-
## time static-graph implementation lands in v2.3 as a drop-in for
## the same surface.
##
## API:
##   let count = signal(0)
##   count()         # read (tracked if inside an effect / computed)
##   count.set(5)    # write
##   createEffect(proc() = echo count())
##   let doubled = createComputed(proc(): int = count() * 2)
##
## Tracking: when a Signal is read inside a Computation's body, the
## Signal records the Computation as an observer; the Computation
## records the Signal as a source. On write, observers re-run. On
## scope dispose, the Computation is marked disposed and removed
## from each of its sources' observer lists.

{.experimental: "callOperator".}

import ./scope
import ./speculative
import ../journal/events
import ../journal/log

type
  Computation* = ref object
    run: proc() {.closure.}
    sources: seq[Subscribable]
    disposed*: bool

  Subscribable = ref object of RootObj
    ## Erased base for "anything observable" so a Computation can
    ## hold a heterogeneous list of sources without generic infection.
    observers: seq[Computation]

  Signal*[T] = ref object of Subscribable
    val: T
    label*: string

var currentComputation* {.threadvar.}: Computation

# --- Signal -----------------------------------------------------------------

proc signal*[T](initial: T, label = ""): Signal[T] =
  Signal[T](val: initial, label: label)

proc trackRead(s: Subscribable) {.gcsafe.} =
  {.cast(gcsafe).}:
    if currentComputation == nil or currentComputation.disposed: return
    if currentComputation notin s.observers:
      s.observers.add currentComputation
      currentComputation.sources.add s

proc get*[T](s: Signal[T]): T {.gcsafe.} =
  trackRead(s)
  s.val

proc `()`*[T](s: Signal[T]): T {.gcsafe.} = s.get()
  ## Sugar — `count()` reads + tracks; same as `count.get()`.

proc notify(s: Subscribable) {.gcsafe, raises: [].} =
  ## Snapshot observers first; a re-run may mutate the list.
  {.cast(gcsafe).}:
    let snap = s.observers
    for c in snap:
      if not c.disposed:
        try: c.run()
        except Exception: discard

proc set*[T](s: Signal[T], newVal: T) {.gcsafe, raises: [].} =
  when compiles(s.val == newVal):
    if s.val == newVal: return
  # Push a revert into the active speculative frame, if any. Captures
  # the prior value by closure so a rollback restores it AND notifies
  # observers so dependent effects re-run.
  if currentSpeculative != nil and not currentSpeculative.committed:
    let captured = s
    let prior = s.val
    recordRevert proc() =
      captured.val = prior
      notify(captured)
  s.val = newVal
  {.cast(gcsafe).}:
    try:
      if globalJournal != nil:
        let tid = if currentScope != nil: currentScope.taskId else: RootTask
        let parent = if currentScope != nil: currentScope.lastEventId else: NoEvent
        let valRepr =
          when compiles($newVal): $newVal
          else: ""
        let id = globalJournal.logStateWrite(tid, parent, s.label, valRepr)
        if currentScope != nil:
          currentScope.lastEventId = id
    except Exception:
      discard
  notify(s)

# --- Computations -----------------------------------------------------------

proc unsubscribeAll(c: Computation) {.gcsafe.} =
  {.cast(gcsafe).}:
    for src in c.sources:
      let idx = src.observers.find(c)
      if idx >= 0: src.observers.del(idx)
    c.sources.setLen(0)

proc createEffect*(body: proc() {.closure.}) {.gcsafe.} =
  ## Run `body` immediately, tracking signal reads; re-run on any
  ## tracked signal's change until the enclosing scope is disposed.
  {.cast(gcsafe).}:
    let comp = Computation()
    comp.run = proc() =
      if comp.disposed: return
      unsubscribeAll(comp)
      let prev = currentComputation
      currentComputation = comp
      try:
        body()
      finally:
        currentComputation = prev
    if currentScope != nil:
      onCleanup proc() =
        comp.disposed = true
        unsubscribeAll(comp)
    comp.run()

template `:=`*[T](s: Signal[T], v: T): untyped =
  ## DSL sugar for signal writes: `count := 5` ≡ `count.set(5)`.
  s.set(v)

import std/macros

macro signals*(body: untyped): untyped =
  ## Declare one or more signals in a colon block:
  ##
  ##   signals:
  ##     count = 0
  ##     title = "hello"
  ##
  ## Named `signals` rather than `state` because chronos exports
  ## `state*(future)` returning FutureState — overload resolution
  ## would shadow our macro any time `import chronos` is in scope.
  ## Single-line `signals x = 0` is not supported — Nim's parser
  ## claims that shape as a named-arg call.
  expectKind(body, nnkStmtList)
  result = newStmtList()
  for stmt in body:
    case stmt.kind
    of nnkAsgn:
      let name = stmt[0]
      let value = stmt[1]
      let labelLit = newLit($name)
      result.add quote do:
        let `name` = signal(`value`, label = `labelLit`)
    else:
      error("state: arm must be `name = value` or `name: Type`; got " &
            stmt.repr, stmt)

proc createComputed*[T](body: proc(): T {.closure.}): Signal[T] {.gcsafe.} =
  ## A derived signal that re-evaluates when its dependencies change.
  ## Reading the returned signal both yields the current value and
  ## subscribes the current computation to it.
  {.cast(gcsafe).}:
    var initial: T
    let outSig = Signal[T](val: initial)
    createEffect proc() =
      outSig.set(body())
    result = outSig
