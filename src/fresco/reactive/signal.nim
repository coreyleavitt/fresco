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

var currentComputation* {.threadvar.}: Computation

# --- Signal -----------------------------------------------------------------

proc signal*[T](initial: T): Signal[T] =
  Signal[T](val: initial)

proc trackRead(s: Subscribable) =
  if currentComputation == nil or currentComputation.disposed: return
  if currentComputation notin s.observers:
    s.observers.add currentComputation
    currentComputation.sources.add s

proc get*[T](s: Signal[T]): T =
  trackRead(s)
  s.val

proc `()`*[T](s: Signal[T]): T = s.get()
  ## Sugar — `count()` reads + tracks; same as `count.get()`.

proc notify(s: Subscribable) =
  ## Snapshot observers first; a re-run may mutate the list.
  let snap = s.observers
  for c in snap:
    if not c.disposed: c.run()

proc set*[T](s: Signal[T], newVal: T) =
  when compiles(s.val == newVal):
    if s.val == newVal: return
  s.val = newVal
  notify(s)

# --- Computations -----------------------------------------------------------

proc unsubscribeAll(c: Computation) =
  for src in c.sources:
    let idx = src.observers.find(c)
    if idx >= 0: src.observers.del(idx)
  c.sources.setLen(0)

proc createEffect*(body: proc() {.closure.}) =
  ## Run `body` immediately, tracking signal reads; re-run on any
  ## tracked signal's change until the enclosing scope is disposed.
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

proc createComputed*[T](body: proc(): T {.closure.}): Signal[T] =
  ## A derived signal that re-evaluates when its dependencies change.
  ## Reading the returned signal both yields the current value and
  ## subscribes the current computation to it.
  var initial: T
  let outSig = Signal[T](val: initial)
  createEffect proc() =
    outSig.set(body())
  outSig
