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

import ./signal
import ./scope

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

proc push*[T](c: CollectionSignal[T], v: T) =
  let idx = c.items.len
  c.items.add v
  emit(c, Delta[T](kind: dkInsert, insertIdx: idx, insertVal: v))

proc pop*[T](c: CollectionSignal[T]): T {.discardable.} =
  doAssert c.items.len > 0, "pop on empty collection"
  let idx = c.items.high
  result = c.items[idx]
  c.items.setLen(idx)
  emit(c, Delta[T](kind: dkRemove, removeIdx: idx))

proc insert*[T](c: CollectionSignal[T], idx: int, v: T) =
  doAssert idx in 0 .. c.items.len, "insert index out of bounds"
  c.items.insert(v, idx)
  emit(c, Delta[T](kind: dkInsert, insertIdx: idx, insertVal: v))

proc remove*[T](c: CollectionSignal[T], idx: int) =
  doAssert idx in 0 ..< c.items.len, "remove index out of bounds"
  c.items.delete(idx)
  emit(c, Delta[T](kind: dkRemove, removeIdx: idx))

proc setAt*[T](c: CollectionSignal[T], idx: int, v: T) =
  doAssert idx in 0 ..< c.items.len, "setAt index out of bounds"
  c.items[idx] = v
  emit(c, Delta[T](kind: dkUpdate, updateIdx: idx, updateVal: v))

proc clear*[T](c: CollectionSignal[T]) =
  if c.items.len == 0: return
  c.items.setLen(0)
  emit(c, Delta[T](kind: dkClear))

proc set*[T](c: CollectionSignal[T], newItems: seq[T]) =
  ## Wholesale replacement. Emits a dkReplace delta — handlers that
  ## want incremental updates should treat this as "redo from scratch."
  c.items = newItems
  emit(c, Delta[T](kind: dkReplace, replaceVal: newItems))
