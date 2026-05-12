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
## **Journal integration:** labeled mutations emit `ekCollectionDelta`
## events. Unlabeled collections skip journaling (same rule as
## `Signal[T].set`). The delta payload preserves enough information
## for forward replay (insert/remove/update/clear/replace), but
## bitemporal `stateAt` projection of collection state is not yet
## implemented — reconstruction requires either replaying from initial
## state or interleaving snapshots, both of which are future work
## (see #38 for inverse-delta reverts).

{.experimental: "callOperator".}

import ./signal
import ./scope
import ./speculative
import ../journal/events
import ../journal/log

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
    items: seq[T]
      ## Internal — read via `get()` or `len()` (which register the
      ## reactive dependency); mutate via the delta-emitting ops.
      ## Direct `.items` access would bypass `trackCollectionRead`,
      ## silently breaking reactive subscription.
    label*: string
      ## Identifier emitted with `ekCollectionDelta` journal events.
      ## Unlabeled collections skip journaling — match the rule for
      ## unlabeled signals so the journal is consistent.
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

proc journalDelta[T](c: CollectionSignal[T], d: Delta[T]) =
  ## Record this mutation in the journal. Skipped for unlabeled
  ## collections (mirrors signal-write rule — projection only works
  ## for labeled state).
  if c.label.len == 0: return
  case d.kind
  of dkInsert:
    let r = when compiles($d.insertVal): $d.insertVal else: ""
    journalEvent: jrnl.logCollectionDelta(taskTid, parentEvt, c.label, "insert", d.insertIdx, r)
  of dkRemove:
    journalEvent: jrnl.logCollectionDelta(taskTid, parentEvt, c.label, "remove", d.removeIdx, "")
  of dkUpdate:
    let r = when compiles($d.updateVal): $d.updateVal else: ""
    journalEvent: jrnl.logCollectionDelta(taskTid, parentEvt, c.label, "update", d.updateIdx, r)
  of dkClear:
    journalEvent: jrnl.logCollectionDelta(taskTid, parentEvt, c.label, "clear", -1, "")
  of dkReplace:
    let r = $d.replaceVal.len   # length-only repr — full repr could be huge
    journalEvent: jrnl.logCollectionDelta(taskTid, parentEvt, c.label, "replace", -1, r)

proc emit[T](c: CollectionSignal[T], d: Delta[T]) =
  ## Fan out to delta-aware handlers AND notify plain reactive
  ## observers so a `createEffect`/`bindRows` that read `c.items` or
  ## `c.len` re-runs on any mutation. The two channels are independent:
  ## handlers see typed deltas, computations see "something changed."
  ## Also journals the mutation if the collection has a label.
  journalDelta(c, d)
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

proc `()`*[T](c: CollectionSignal[T]): seq[T] = c.get()
  ## Sugar — `items()` reads + tracks; same as `items.get()`.
  ## Mirrors `Signal[T]`'s `()` operator for API symmetry. Requires
  ## `{.experimental: "callOperator".}` at the call site.

proc len*[T](c: CollectionSignal[T]): int =
  ## Length of the collection. Tracked: a `createEffect` / `tracked:`
  ## body that reads `.len` re-runs when the collection mutates.
  trackCollectionRead(c)
  c.items.len

# --- Delta-emitting ops --------------------------------------------------

template withRevert[T](c: CollectionSignal[T], body: untyped) =
  ## Push a revert closure that restores `c.items` before running
  ## `body`. Inside a `speculative:` block, falling out without
  ## commit drains the closure and emits a `dkReplace` delta so
  ## observers re-render against the restored state. **Outside a
  ## speculative scope this is a zero-cost no-op (no copy, no
  ## allocation) — the snapshot only happens when reversion is
  ## actually possible.**
  ##
  ## **Snapshot semantics:** we capture the full prior items seq
  ## rather than an inverse delta. For the v2.3 use case (small
  ## collections, few mutations per block) the per-mutation O(N)
  ## copy and O(N×M) memory across M mutations is acceptable. v2.4's
  ## `ekCollectionDelta` journal integration will revisit this with
  ## inverse-deltas (`dkInsert` ↔ `dkRemove` at the same index, etc.)
  ## to amortize the cost.
  ##
  ## **Multi-mutation rollback** fires one `dkReplace` per mutation
  ## (LIFO) — M mutations produce M re-render passes. Correct but
  ## potentially inefficient; batch coalescing not implemented.
  ##
  ## The outer guard duplicates a check that `recordRevert` also
  ## performs internally. The duplication is deliberate — it avoids
  ## the seq-copy + closure allocation when there's no active frame.
  ## If you change the condition here, change it in
  ## `speculative.nim:recordRevert` too (single source of truth would
  ## require always allocating, which defeats the point).
  if currentSpeculative != nil and not currentSpeculative.committed:
    let priorItems = c.items   # plain copy — only when needed
    let captured = c
    recordRevert proc() =
      captured.items = priorItems
      emit(captured, Delta[T](kind: dkReplace, replaceVal: priorItems))
  body

proc push*[T](c: CollectionSignal[T], v: T) =
  ## Append `v`. Emits `dkInsert` with the appended index.
  withRevert(c):
    let idx = c.items.len
    c.items.add v
    emit(c, Delta[T](kind: dkInsert, insertIdx: idx, insertVal: v))

proc pop*[T](c: CollectionSignal[T]): T {.discardable.} =
  ## Remove and return the last element. **Asserts on empty.**
  doAssert c.items.len > 0, "pop on empty collection"
  withRevert(c):
    let idx = c.items.high
    result = c.items[idx]
    c.items.setLen(idx)
    emit(c, Delta[T](kind: dkRemove, removeIdx: idx))

proc insert*[T](c: CollectionSignal[T], idx: int, v: T) =
  ## Insert `v` at `idx` (valid range: `0 .. len`, inclusive — `len`
  ## inserts at the end). **Asserts on out-of-bounds.**
  doAssert idx in 0 .. c.items.len, "insert index out of bounds"
  withRevert(c):
    c.items.insert(v, idx)
    emit(c, Delta[T](kind: dkInsert, insertIdx: idx, insertVal: v))

proc remove*[T](c: CollectionSignal[T], idx: int) =
  ## Remove the element at `idx`. **Asserts on out-of-bounds.**
  doAssert idx in 0 ..< c.items.len, "remove index out of bounds"
  withRevert(c):
    c.items.delete(idx)
    emit(c, Delta[T](kind: dkRemove, removeIdx: idx))

proc setAt*[T](c: CollectionSignal[T], idx: int, v: T) =
  ## Replace the element at `idx`. **Asserts on out-of-bounds.**
  doAssert idx in 0 ..< c.items.len, "setAt index out of bounds"
  withRevert(c):
    c.items[idx] = v
    emit(c, Delta[T](kind: dkUpdate, updateIdx: idx, updateVal: v))

proc clear*[T](c: CollectionSignal[T]) =
  ## Remove all elements. No-op on an already-empty collection
  ## (no delta emitted in that case).
  if c.items.len == 0: return
  withRevert(c):
    c.items.setLen(0)
    emit(c, Delta[T](kind: dkClear))

proc set*[T](c: CollectionSignal[T], newItems: seq[T]) =
  ## Wholesale replacement. Emits a dkReplace delta — handlers that
  ## want incremental updates should treat this as "redo from scratch."
  withRevert(c):
    c.items = newItems
    emit(c, Delta[T](kind: dkReplace, replaceVal: newItems))
