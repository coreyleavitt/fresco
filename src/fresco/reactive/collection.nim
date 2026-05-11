## Differential collections — `Signal[seq[T]]` with delta-tracked ops.
##
## Append-only logs, scrollback buffers, and streaming token output
## all want incremental rendering — only paint the new row, not the
## whole region every time the seq grows. A `Signal[seq[T]]` can't
## express that: every write replaces the whole value, and the binding
## has no way to know "only the last row changed."
##
## CollectionSignal carries the same value type but adds delta-emitting
## operations (`push`, `pop`, `insert`, `remove`, `setAt`, `clear`).
## Subscribers can register handlers that receive a typed Delta and
## apply incremental updates. Plain `notify` still fires too, so
## non-delta-aware observers keep working.
##
## **Speculative scope support:** mutations inside a `speculative:`
## block snapshot the prior items seq and record a revert closure, the
## same way `Signal[T].set` does. Falling out of the block without
## commit replays the reverts in reverse, restoring the collection's
## pre-block state and firing a `dkReplace` delta so observers
## re-render.
##
## **v2.3 limitation — no journal integration:** unlike `Signal[T].set`
## which emits `ekSignalWrite` events, CollectionSignal mutations are
## not journaled. This means bitemporal projection (`stateAt` /
## `stateAtTime`) and state restoration via `lastWritesByLabel` cover
## scalar signal state but **not** collection state. v2.4 will add an
## `ekCollectionDelta` event variant and wire emit() through journalEvent;
## until then, treat collection state as ephemeral (not replayable).

import ./signal
import ./scope
import ./speculative

type
  DeltaKind* = enum
    dkInsert
    dkRemove
    dkUpdate
    dkClear
    dkReplace

  Delta*[T] = object
    case kind*: DeltaKind
    of dkInsert:
      insertIdx*: int
      insertVal*: T
    of dkRemove:
      removeIdx*: int
    of dkUpdate:
      updateIdx*: int
      updateVal*: T
    of dkClear:
      discard
    of dkReplace:
      replaceVal*: seq[T]

  DeltaHandler*[T] = proc(d: Delta[T]) {.closure.}

  CollectionSignal*[T] = ref object of Subscribable
    items*: seq[T]
    label*: string
    deltaObservers: seq[DeltaHandler[T]]

proc collection*[T](initial: seq[T] = @[], label = ""): CollectionSignal[T] =
  ## Constructor matching the `signal(initial)` naming for plain signals.
  CollectionSignal[T](items: initial, label: label)

# --- Subscription --------------------------------------------------------

proc onDelta*[T](c: CollectionSignal[T], handler: DeltaHandler[T]) =
  ## Register `handler` to receive every delta. Lifetime-bound to the
  ## current scope via onCleanup so it deregisters when the scope dies.
  c.deltaObservers.add handler
  let captured = c
  let h = handler
  onCleanup proc() =
    let idx = captured.deltaObservers.find(h)
    if idx >= 0: captured.deltaObservers.del idx

proc emit[T](c: CollectionSignal[T], d: Delta[T]) =
  ## Fan out to delta-aware handlers AND notify plain reactive
  ## observers so a `createEffect`/`bindRows` that read `c.items` or
  ## `c.len` re-runs on any mutation. The two channels are independent:
  ## handlers see typed deltas, computations see "something changed."
  let snap = c.deltaObservers
  for h in snap:
    try: h(d)
    except Exception: discard
      # User-supplied delta handler — same swallow rationale as
      # signal.notify: a faulty observer shouldn't break siblings
      # or propagate out through the mutating call.
  notify(Subscribable(c))

proc trackCollectionRead[T](c: CollectionSignal[T]) =
  ## Subscribe the current Computation (if any) to this collection.
  ## Called from `get` / `len` so plain reactive code that reads
  ## these naturally tracks them.
  if currentComputation == nil or currentComputation.disposed: return
  if currentComputation notin Subscribable(c).observers:
    Subscribable(c).observers.add currentComputation
    currentComputation.sources.add Subscribable(c)

# --- Read ----------------------------------------------------------------

proc get*[T](c: CollectionSignal[T]): seq[T] =
  ## Snapshot of the current items. Returns by value; callers don't
  ## mutate this — use the delta-emitting ops below.
  trackCollectionRead(c)
  c.items

proc len*[T](c: CollectionSignal[T]): int =
  trackCollectionRead(c)
  c.items.len

# --- Delta-emitting ops --------------------------------------------------

proc recordCollectionRevert[T](c: CollectionSignal[T],
                               prior: sink seq[T]) =
  ## Push a revert that restores the collection's full prior items
  ## seq. Only fires inside a `speculative:` block; otherwise no-op.
  ## We snapshot the whole seq rather than the inverse-delta because:
  ## (a) revert closures already execute as a stack on block exit, so
  ## the cost is one snapshot per mutation, not one inverse-op
  ## reconstruction; (b) `dkReplace` and `dkClear` would need full
  ## snapshots anyway; uniform snapshotting keeps the code simple and
  ## the semantics obvious.
  if currentSpeculative == nil or currentSpeculative.committed: return
  let captured = c
  let priorItems = prior
  recordRevert proc() =
    captured.items = priorItems
    emit(captured, Delta[T](kind: dkReplace, replaceVal: priorItems))

proc push*[T](c: CollectionSignal[T], v: T) =
  ## Append `v`. Emits `dkInsert` with the appended index.
  recordCollectionRevert(c, c.items)
  let idx = c.items.len
  c.items.add v
  emit(c, Delta[T](kind: dkInsert, insertIdx: idx, insertVal: v))

proc pop*[T](c: CollectionSignal[T]): T {.discardable.} =
  ## Remove and return the last element. **Asserts on empty.**
  doAssert c.items.len > 0, "pop on empty collection"
  recordCollectionRevert(c, c.items)
  let idx = c.items.high
  result = c.items[idx]
  c.items.setLen(idx)
  emit(c, Delta[T](kind: dkRemove, removeIdx: idx))

proc insert*[T](c: CollectionSignal[T], idx: int, v: T) =
  ## Insert `v` at `idx` (valid range: `0 .. len`, inclusive — `len`
  ## inserts at the end). **Asserts on out-of-bounds.**
  doAssert idx in 0 .. c.items.len, "insert index out of bounds"
  recordCollectionRevert(c, c.items)
  c.items.insert(v, idx)
  emit(c, Delta[T](kind: dkInsert, insertIdx: idx, insertVal: v))

proc remove*[T](c: CollectionSignal[T], idx: int) =
  ## Remove the element at `idx`. **Asserts on out-of-bounds.**
  doAssert idx in 0 ..< c.items.len, "remove index out of bounds"
  recordCollectionRevert(c, c.items)
  c.items.delete(idx)
  emit(c, Delta[T](kind: dkRemove, removeIdx: idx))

proc setAt*[T](c: CollectionSignal[T], idx: int, v: T) =
  ## Replace the element at `idx`. **Asserts on out-of-bounds.**
  doAssert idx in 0 ..< c.items.len, "setAt index out of bounds"
  recordCollectionRevert(c, c.items)
  c.items[idx] = v
  emit(c, Delta[T](kind: dkUpdate, updateIdx: idx, updateVal: v))

proc clear*[T](c: CollectionSignal[T]) =
  ## Remove all elements. No-op on an already-empty collection
  ## (no delta emitted in that case).
  if c.items.len == 0: return
  recordCollectionRevert(c, c.items)
  c.items.setLen(0)
  emit(c, Delta[T](kind: dkClear))

proc set*[T](c: CollectionSignal[T], newItems: seq[T]) =
  ## Wholesale replacement. Emits a dkReplace delta — handlers that
  ## want incremental updates should treat this as "redo from scratch."
  recordCollectionRevert(c, c.items)
  c.items = newItems
  emit(c, Delta[T](kind: dkReplace, replaceVal: newItems))
