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
## ## ObserverList: RCU-inspired stable iteration
##
## `Subscribable.observers` is an `ObserverList`, not a plain
## `seq[Computation]`. The list supports the "iterate while callbacks
## mutate the list" pattern that reactive `notify` requires:
##
## - `iterRO` opens a read-side critical section; iteration walks the
##   items present at section entry.
## - During iteration, `add`/`remove` queue into a pending buffer.
## - The buffer flushes when the outermost iteration exits.
##
## Contract:
##  * Observers added mid-notify do NOT fire the current cycle; they
##    appear in subsequent cycles.
##  * Observers removed-but-not-disposed during a cycle still fire
##    the current cycle (we iterate the entry-time snapshot).
##  * The pending queue's ops apply in queue order at flush.
##
## This is the inverse of the silent-corruption mode that Nim 2.x ORC
## cursor inference would otherwise produce on `let snap = liveSeq`:
## by encoding the invariant in a type, the bug class becomes
## structurally unrepresentable. See `nim-cycle-destroy-reentry.patch`
## under `patches/` for the related Nim runtime fix that makes our
## cycle (Subscribable.observers ⇄ Computation.sources) safe to
## destruct.

type
  ObserverList* = object
    items*: seq[Computation]
    iterDepth: int
    pendingVals: seq[Computation]
    pendingIsAdd: seq[bool]

  Subscribable* = ref object of RootObj
    ## Erased base for "anything observable" so a Computation can
    ## hold a heterogeneous list of sources without generic infection.
    ## All reactive primitives in fresco inherit from this.
    observers*: ObserverList

  Computation* = ref object
    ## The observer side of the reactive graph. Holds a closure to
    ## re-run on dep change, plus the set of Subscribable sources it
    ## currently observes (for `unsubscribeAll` cleanup).
    run*: proc() {.closure.}
    sources*: seq[Subscribable]
    disposed*: bool

proc len*(o: ObserverList): int {.inline.} = o.items.len
proc `[]`*(o: ObserverList, i: int): Computation {.inline.} = o.items[i]

proc flushPending(o: var ObserverList) =
  if o.pendingVals.len == 0: return
  for i in 0 ..< o.pendingVals.len:
    if o.pendingIsAdd[i]:
      o.items.add o.pendingVals[i]
    else:
      let idx = o.items.find(o.pendingVals[i])
      if idx >= 0: o.items.del(idx)
  o.pendingVals.setLen(0)
  o.pendingIsAdd.setLen(0)

proc add*(o: var ObserverList, c: Computation) =
  ## Append `c`. Deferred to outermost-iteration exit if called from
  ## within an `iterRO` section.
  if o.iterDepth > 0:
    o.pendingVals.add c
    o.pendingIsAdd.add true
  else:
    o.items.add c

proc remove*(o: var ObserverList, c: Computation) =
  ## Remove `c`. Deferred to outermost-iteration exit if called from
  ## within an `iterRO` section. Idempotent (already-absent values
  ## are no-ops at flush time).
  if o.iterDepth > 0:
    o.pendingVals.add c
    o.pendingIsAdd.add false
  else:
    let idx = o.items.find(c)
    if idx >= 0: o.items.del(idx)

proc contains*(o: ObserverList, c: Computation): bool =
  ## Membership reflects post-flush state — pending adds count as
  ## present, pending removes count as absent. Critical inside a
  ## notify cycle: an effect's `trackRead` does `c notin s.observers`
  ## to decide whether to re-subscribe; with a pending-remove queued
  ## on `c`, that check must say "not present" so the trackRead's add
  ## fires and survives the flush.
  result = o.items.contains(c)
  for i in 0 ..< o.pendingVals.len:
    if o.pendingVals[i] == c:
      result = o.pendingIsAdd[i]

template iterRO*(o: var ObserverList, elem, body: untyped) =
  ## Iterate `o.items` in entry-order. `elem` is bound to each item.
  ## Mutations to `o` from `body` are deferred until the outermost
  ## iteration exits.
  inc o.iterDepth
  try:
    let startLen = o.items.len
    var i = 0
    while i < startLen:
      let elem = o.items[i]
      inc i
      body
  finally:
    dec o.iterDepth
    if o.iterDepth == 0:
      o.flushPending()

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
  ## If called from within a `notify` cycle on `s`, the add is
  ## deferred to the cycle's outermost exit (see `ObserverList`).
  {.cast(gcsafe).}:
    if c.disposed: return
    if c notin s.observers:
      s.observers.add c
      c.sources.add s

proc trackRead*(s: Subscribable) {.gcsafe.} =
  ## Register the current Computation (if any) as an observer of `s`.
  ## Called from each reactive type's read entry points so plain
  ## reactive code that reads them naturally tracks them. No-op
  ## outside a Computation body.
  {.cast(gcsafe).}:
    if currentComputation == nil or currentComputation.disposed: return
    if currentComputation notin s.observers:
      s.observers.add currentComputation
      currentComputation.sources.add s

proc notify*(s: Subscribable) {.gcsafe, raises: [].} =
  ## Fire every Computation observing `s` in subscription order.
  ## A re-run may subscribe/unsubscribe against `s` (an effect that
  ## resubscribes to different sources, or disposes itself) — those
  ## structural mutations are queued and applied when the outermost
  ## iteration exits, so the current pass yields exactly the set of
  ## observers that existed at entry. A raising observer is
  ## swallowed: `c.run` is a user closure, and a faulty observer
  ## shouldn't break sibling observers or the writing task.
  {.cast(gcsafe).}:
    s.observers.iterRO c:
      if not c.disposed:
        try: c.run()
        except Exception: discard

proc unsubscribeAll*(c: Computation) {.gcsafe.} =
  ## Detach `c` from every Subscribable it currently observes. Called
  ## by `createEffect` before re-running (to rebuild deps cleanly) and
  ## by the `onCleanup` emitted in `tracked:` blocks. Exported because
  ## macro-emitted code lives in user scope; not typically called by
  ## user code directly. If called from within a notify cycle on a
  ## given source, that source's removal is deferred.
  ##
  ## **Cursor hazard.** Nim's cursor inference treats the `c: Computation`
  ## parameter as non-retaining — calling this proc does NOT add a
  ## strong reference. The body removes `c` from each source's
  ## observers list (via `src.observers.remove c`), and that removal
  ## decrements `c`'s refcount. If the caller held the only remaining
  ## strong ref (e.g., the source's observers entry WAS the last one),
  ## the in-loop decref takes `c` to zero, destroys it, and the next
  ## iteration's read of `c.sources` is a use-after-free. The
  ## `var alive {.nocursor.} = c` pins a strong ref for the lifetime
  ## of the proc.
  {.cast(gcsafe).}:
    var alive = c            # defeat cursor inference — strong ref
    for src in alive.sources:
      src.observers.remove alive
    alive.sources.setLen(0)
