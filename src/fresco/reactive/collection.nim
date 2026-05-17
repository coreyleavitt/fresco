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
## **Speculative scope support:** each mutation captures an O(1)
## *inverse delta* (push ↔ remove-at-idx, remove ↔ insert-at-idx with
## the prior value, etc.) into a per-collection per-scope buffer.
## `clear` and `set` still snapshot the full prior seq — they're the
## only two structurally-destructive ops. On rollback the buffer
## applies in reverse and observers receive ONE batched `dkRollback`
## delta carrying every inverse, not M individual reverse-deltas.
## Total memory cost across M mutations is O(M) for the common cases,
## not O(N×M).
##
## **Journal integration:** labeled mutations emit `ekCollectionDelta`
## events. On rollback, a single `ekCollectionRollback` event records
## the entire reverted sequence per affected labeled collection — the
## audit trail distinguishes user actions from system rollbacks.
## Unlabeled collections skip journaling (same rule as
## `Signal[T].set`).

{.experimental: "callOperator".}

import ./subscribable
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
    dkRollback     ## Batched reverse of speculative-scope mutations. Carries
                   ## the inverse ops in `rollbackOps`, applied right-to-left.

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
    of dkRollback:
      rollbackOps*: seq[Delta[T]]   ## inverses in CHRONOLOGICAL order; the
                                    ## applier walks them in reverse to undo

  DeltaHandler*[T] = proc(d: Delta[T]) {.closure.}

  RollbackBufferEntry[T] = ref object
    ## Per-collection per-scope buffer of captured inverses, chained
    ## up through parent speculative frames so nested commit can
    ## promote into the parent.
    scope: SpeculativeScope
    inverses: seq[Delta[T]]
    next: RollbackBufferEntry[T]

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
    rollbackHead: RollbackBufferEntry[T]
      ## Top of the per-scope buffer chain; nil outside speculative
      ## scopes. Mutated only by `captureInverse` and the registered
      ## commit/rollback hooks.

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

proc opRepr[T](d: Delta[T]): string =
  ## Compact one-token repr of a non-rollback delta for the journal
  ## rollback payload. Format: `kind[:idx[:val]]` joined with `;`.
  ## Designed for forward replay — parseable without ambiguity since
  ## the kind letter dictates which trailing fields are present.
  case d.kind
  of dkInsert:
    let v = when compiles($d.insertVal): $d.insertVal else: ""
    "i:" & $d.insertIdx & ":" & v
  of dkRemove:  "r:" & $d.removeIdx
  of dkUpdate:
    let v = when compiles($d.updateVal): $d.updateVal else: ""
    "u:" & $d.updateIdx & ":" & v
  of dkClear:   "c"
  of dkReplace: "p:" & $d.replaceVal.len
  of dkRollback: ""   # rollback inverses never contain nested rollbacks

proc applyDelta[T](c: CollectionSignal[T], d: Delta[T]) =
  ## Apply `d` to the collection's items WITHOUT emitting observers or
  ## journaling. Used by the rollback hook to restore state before
  ## firing the single batched notification. For `dkRollback` walks
  ## the inverse seq right-to-left (chronological reversal).
  case d.kind
  of dkInsert:  c.items.insert(d.insertVal, d.insertIdx)
  of dkRemove:  c.items.delete(d.removeIdx)
  of dkUpdate:  c.items[d.updateIdx] = d.updateVal
  of dkClear:   c.items.setLen(0)
  of dkReplace: c.items = d.replaceVal
  of dkRollback:
    for i in countdown(d.rollbackOps.high, 0):
      applyDelta(c, d.rollbackOps[i])

proc journalDelta[T](c: CollectionSignal[T], d: Delta[T]) =
  ## Record this forward mutation in the journal. Skipped for
  ## unlabeled collections. `dkRollback` is journaled via the
  ## dedicated `ekCollectionRollback` event from the rollback hook,
  ## not here.
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
  of dkRollback: discard

proc journalRollback[T](c: CollectionSignal[T], d: Delta[T]) =
  ## Record a single rollback as one `ekCollectionRollback` event.
  ## Skipped for unlabeled collections.
  if c.label.len == 0: return
  if d.kind != dkRollback: return
  var ops = ""
  for i, inv in d.rollbackOps:
    if i > 0: ops.add ';'
    ops.add opRepr(inv)
  journalEvent:
    jrnl.logCollectionRollback(taskTid, parentEvt, c.label, d.rollbackOps.len, ops)

proc fanout[T](c: CollectionSignal[T], d: Delta[T]) =
  ## Notify delta-aware handlers and trigger plain reactive
  ## observers. No journaling — the caller decides which event
  ## (`ekCollectionDelta` per forward op, `ekCollectionRollback`
  ## once per rolled-back collection) to write.
  ##
  ## Explicit-copy snapshot defeats Nim's cursor inference. A
  ## handler body that triggers deregistration (e.g. a sibling
  ## scope's onCleanup calling `c.deltaObservers.del idx`) mutates
  ## the live seq mid-fanout; an aliased snapshot would corrupt
  ## the in-progress iteration. Per-handler `add` materializes a
  ## genuine independent buffer.
  # Iterate by index over the deltaObservers, capturing startLen once.
  # Defeats Nim's cursor-inference hazard where `let snap =
  # c.deltaObservers` becomes a non-retaining cursor of the live seq:
  # a handler that triggers deregistration (e.g. via a sibling
  # scope's onCleanup calling `c.deltaObservers.del idx`) would
  # corrupt the iteration. Bounds-check on every step so a `del`
  # that shifts the live seq doesn't run us past valid indices —
  # mid-fanout deregistration skips not-yet-fired handlers (matching
  # the Signal.observers RCU contract: structural mutations during
  # notify apply on subsequent cycles).
  let startLen = c.deltaObservers.len
  var i = 0
  while i < c.deltaObservers.len and i < startLen:
    let h = c.deltaObservers[i]
    inc i
    try: h(d)
    except Exception: discard
      # User-supplied delta handler — same swallow rationale as
      # signal.notify: a faulty observer shouldn't break siblings
      # or propagate out through the mutating call.
  notify(Subscribable(c))

proc emit[T](c: CollectionSignal[T], d: Delta[T]) =
  ## Fan out + journal a forward mutation.
  journalDelta(c, d)
  fanout(c, d)

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

# --- Speculative-rollback machinery --------------------------------------

proc captureInverse[T](c: CollectionSignal[T], inv: Delta[T]) =
  ## Outside a speculative scope: zero-cost no-op. Inside one: append
  ## `inv` to this collection's per-scope buffer, and on first mutation
  ## in this scope register the commit/rollback hooks that promote or
  ## drain the buffer.
  ##
  ## The first-mutation check (`rollbackHead == nil` or `scope mismatch`)
  ## avoids re-registering hooks every mutation. Hooks fire exactly once
  ## per (collection, scope) per scope-exit; subsequent mutations in the
  ## same scope just append.
  if currentSpeculative != nil and not currentSpeculative.committed:
    if c.rollbackHead == nil or c.rollbackHead.scope != currentSpeculative:
      let entry = RollbackBufferEntry[T](
        scope: currentSpeculative,
        inverses: @[],
        next: c.rollbackHead)
      c.rollbackHead = entry
      let captured = c
      onSpeculativeRollback proc() =
        # Head is guaranteed to be `entry` here: rollback hooks fire
        # before any further mutation could re-target it, and nested
        # scopes that committed/rolled-back already popped their entries.
        let head = captured.rollbackHead
        let batched = Delta[T](kind: dkRollback, rollbackOps: head.inverses)
        applyDelta(captured, batched)
        journalRollback(captured, batched)
        fanout(captured, batched)
        captured.rollbackHead = head.next
      onSpeculativeCommit proc() =
        # Promote inverses into the parent buffer if one exists so an
        # outer rollback still undoes our work. At the outermost scope
        # they're discarded — commit makes the writes canonical.
        let head = captured.rollbackHead
        if head.next != nil:
          for inv in head.inverses: head.next.inverses.add inv
        captured.rollbackHead = head.next
    c.rollbackHead.inverses.add inv

# --- Delta-emitting ops --------------------------------------------------

proc push*[T](c: CollectionSignal[T], v: T) =
  ## Append `v`. Emits `dkInsert` with the appended index.
  let idx = c.items.len
  captureInverse(c, Delta[T](kind: dkRemove, removeIdx: idx))
  c.items.add v
  emit(c, Delta[T](kind: dkInsert, insertIdx: idx, insertVal: v))

proc pop*[T](c: CollectionSignal[T]): T {.discardable.} =
  ## Remove and return the last element. **Asserts on empty.**
  doAssert c.items.len > 0, "pop on empty collection"
  let idx = c.items.high
  result = c.items[idx]
  captureInverse(c, Delta[T](kind: dkInsert, insertIdx: idx, insertVal: result))
  c.items.setLen(idx)
  emit(c, Delta[T](kind: dkRemove, removeIdx: idx))

proc insert*[T](c: CollectionSignal[T], idx: int, v: T) =
  ## Insert `v` at `idx` (valid range: `0 .. len`, inclusive — `len`
  ## inserts at the end). **Asserts on out-of-bounds.**
  doAssert idx in 0 .. c.items.len, "insert index out of bounds"
  captureInverse(c, Delta[T](kind: dkRemove, removeIdx: idx))
  c.items.insert(v, idx)
  emit(c, Delta[T](kind: dkInsert, insertIdx: idx, insertVal: v))

proc remove*[T](c: CollectionSignal[T], idx: int) =
  ## Remove the element at `idx`. **Asserts on out-of-bounds.**
  doAssert idx in 0 ..< c.items.len, "remove index out of bounds"
  let oldVal = c.items[idx]
  captureInverse(c, Delta[T](kind: dkInsert, insertIdx: idx, insertVal: oldVal))
  c.items.delete(idx)
  emit(c, Delta[T](kind: dkRemove, removeIdx: idx))

proc setAt*[T](c: CollectionSignal[T], idx: int, v: T) =
  ## Replace the element at `idx`. **Asserts on out-of-bounds.**
  doAssert idx in 0 ..< c.items.len, "setAt index out of bounds"
  let oldVal = c.items[idx]
  captureInverse(c, Delta[T](kind: dkUpdate, updateIdx: idx, updateVal: oldVal))
  c.items[idx] = v
  emit(c, Delta[T](kind: dkUpdate, updateIdx: idx, updateVal: v))

proc clear*[T](c: CollectionSignal[T]) =
  ## Remove all elements. No-op on an already-empty collection
  ## (no delta emitted in that case). One of two structurally-
  ## destructive ops; its inverse captures the full prior seq (O(N)).
  if c.items.len == 0: return
  captureInverse(c, Delta[T](kind: dkReplace, replaceVal: c.items))
  c.items.setLen(0)
  emit(c, Delta[T](kind: dkClear))

proc set*[T](c: CollectionSignal[T], newItems: seq[T]) =
  ## Wholesale replacement. Emits a dkReplace delta — handlers that
  ## want incremental updates should treat this as "redo from scratch."
  ## The other structurally-destructive op; inverse captures full
  ## prior seq (O(N)).
  captureInverse(c, Delta[T](kind: dkReplace, replaceVal: c.items))
  c.items = newItems
  emit(c, Delta[T](kind: dkReplace, replaceVal: newItems))
