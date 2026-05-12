## Subscribable substrate — the contract every reactive type implements.
##
## This module defines the *substrate*: the base type all observable
## reactive primitives inherit from, the Computation type that holds the
## observer side of the graph, and the substrate procs (`subscribe`,
## `trackRead`, `notify`, `unsubscribeAll`) that wire them together.
##
## ## Writing a reactive type
##
## A reactive type is any `ref object of Subscribable` that exposes
## read entry points calling `trackRead(self)` and mutation entry points
## calling `notify(self)`. The `tracked:` macro detects reads of any
## Subscribable subtype structurally via the type system — no
## registration, no pragma, no name list. To make your type trackable,
## just inherit:
##
##   type MyReactive*[T] = ref object of Subscribable
##     value: T
##
##   proc get*[T](r: MyReactive[T]): T =
##     trackRead(r)
##     r.value
##
##   proc set*[T](r: MyReactive[T], v: T) =
##     r.value = v
##     notify(r)
##
## ## Participating in speculative scopes
##
## To make your type revertible inside `speculative:` blocks, your
## mutators (when `currentSpeculative != nil and not committed`) must
## record how to undo themselves. fresco provides three primitives in
## `speculative.nim`:
##
## - `onSpeculativeRevert(p)` — push a per-write restore closure. The
##   closure runs in LIFO order on rollback and should restore prior
##   state AND call `notify(self)` so dependent effects re-render.
##   Reference: `Signal[T].setCore`.
##
## - `onSpeculativeRollback(p)` / `onSpeculativeCommit(p)` — per-scope
##   batched hooks. Use these when your type wants ONE rollback
##   notification per scope-exit instead of M per-mutation reverts.
##   Reference: `CollectionSignal[T].captureInverse` and the
##   `RollbackBufferEntry` chain.
##
## Pick per-write reverts for scalar types (the closure is small,
## batching adds nothing). Pick batched hooks for structural types
## where M individual notifications would be wasteful and the inverse
## representation is non-trivial.

type
  Subscribable* = ref object of RootObj
    ## Erased base for "anything observable" so a Computation can
    ## hold a heterogeneous list of sources without generic infection.
    ## All reactive primitives in fresco inherit from this.
    observers*: seq[Computation]

  Computation* = ref object
    ## The observer side of the reactive graph. Holds a closure to
    ## re-run on dep change, plus the set of Subscribable sources it
    ## currently observes (for `unsubscribeAll` cleanup).
    run*: proc() {.closure.}
    sources*: seq[Subscribable]
    disposed*: bool

var currentComputation* {.threadvar.}: Computation
  ## Thread-local "currently running Computation," set by
  ## `createEffect` / `createComputed` while the body executes so
  ## reads inside the body can register themselves dynamically via
  ## `trackRead`. The `tracked:` macro does NOT touch this — it emits
  ## explicit `subscribe` calls at compile time.

# --- Subscription ----------------------------------------------------------

proc subscribe*(s: Subscribable, c: Computation) {.gcsafe.} =
  ## Explicit static subscription: wire `c` as an observer of `s`
  ## without going through the runtime `currentComputation` stack.
  ## Used by the typed-macro layer (`tracked:`) to emit compile-time-
  ## known dep edges. Idempotent — re-subscribing is a no-op.
  {.cast(gcsafe).}:
    if c.disposed: return
    if c notin s.observers:
      s.observers.add c
      c.sources.add s

proc trackRead*(s: Subscribable) {.gcsafe.} =
  ## Register the current Computation (if any) as an observer of `s`.
  ## Called from each reactive type's read entry points so plain
  ## reactive code that reads them naturally tracks them. No-op
  ## outside a Computation body (e.g. one-shot reads in user code).
  {.cast(gcsafe).}:
    if currentComputation == nil or currentComputation.disposed: return
    if currentComputation notin s.observers:
      s.observers.add currentComputation
      currentComputation.sources.add s

proc notify*(s: Subscribable) {.gcsafe, raises: [].} =
  ## Fire every Computation observing `s`. Snapshots the observer
  ## list first since a re-run may mutate it (an effect that
  ## resubscribes to different sources, or disposes itself). A
  ## raising observer is swallowed — `c.run` is a user closure, and
  ## a faulty observer shouldn't break sibling observers or the
  ## writing task.
  {.cast(gcsafe).}:
    let snap = s.observers
    for c in snap:
      if not c.disposed:
        try: c.run()
        except Exception: discard

proc unsubscribeAll*(c: Computation) {.gcsafe.} =
  ## Detach `c` from every Subscribable it currently observes. Called
  ## by `createEffect` before re-running (to rebuild deps cleanly) and
  ## by the `onCleanup` emitted in `tracked:` blocks. Exported because
  ## macro-emitted code lives in user scope; not typically called by
  ## user code directly.
  {.cast(gcsafe).}:
    for src in c.sources:
      let idx = src.observers.find(c)
      if idx >= 0: src.observers.del(idx)
    c.sources.setLen(0)
