## Append-only in-memory event log.
##
## A single process-wide log captures every journaled event in the
## order it was produced. v2.1 is in-memory only; v2.4 lifts the same
## append-only API onto a persistent on-disk backing.
##
## Causal tracking: each `append` accepts a `parentId` so the macro
## layer (later) can record the dependency edge automatically at
## spawn / await / emit sites. Bitemporal projection (v2.2) reads
## the log forward up to an observation cursor to reconstruct state
## at any historical point.

import std/[tables, times, sequtils]
import chronos
import ./events
import intonaco/reactive/scope

type
  Snapshot* = object
    ## Compaction frame: per-label final writeRepr as of `atEventId`.
    ## A journal that has never been compacted holds the zero-value
    ## Snapshot (atEventId == NoEvent, empty state). After
    ## `compactBefore(cutoff)`, the snapshot's `atEventId == cutoff`
    ## and `state` carries the last writeRepr for every label that
    ## appeared at or before the cutoff. Events with id ≤ cutoff are
    ## then dropped from `events`.
    atEventId*: EventId
    atWall*: Time
    state*: Table[string, string]

  Journal* = ref object of RootObj
    events*: seq[Event]
    snapshots*: seq[Snapshot]
      ## Multi-tier snapshot index (#49). Ordered by `atEventId`
      ## ascending. `stateAt(cutoff)` binary-searches for the largest
      ## snapshot ≤ cutoff and replays events forward from there.
      ## When the journal is empty (no snapshots have been taken),
      ## this is `@[]` and queries use the in-events path only.
      ## Promotion/coarsening policies operate on this seq.

template base*(j: Journal): Snapshot =
  ## Backward-compat accessor: the oldest snapshot, or a zero
  ## Snapshot if none. Used by code from before the multi-snapshot
  ## migration; new code should use `snapshots` directly.
  if j.snapshots.len > 0: j.snapshots[0] else: Snapshot()

method onPersist*(j: Journal, e: Event) {.base, gcsafe, raises: [].} = discard
  ## Persistence hook fired after an event is appended. Default
  ## implementation does nothing; PersistentJournal overrides it to
  ## flush the event to disk.

method onSnapshotAppended*(j: Journal, s: Snapshot)
                          {.base, gcsafe, raises: [].} = discard
  ## Persistence hook fired after `addSnapshot` appends a new
  ## Snapshot to `j.snapshots`. Default no-op; PersistentJournal
  ## overrides it to flush a snapshot frame to disk so multi-
  ## snapshot history survives reopens.

var rewindingFlag* {.threadvar.}: bool
  ## Set by `timewarp.rewindTo` for the duration of a projection;
  ## consulted by `signal.setCore` to skip journaling. Living here
  ## rather than in timewarp.nim avoids a `signal → timewarp` import
  ## cycle (signal.nim already imports this module).

proc isRewinding*(): bool {.gcsafe.} = rewindingFlag

var globalJournal* {.threadvar.}: Journal
  ## **Thread-local** active journal. Installed via `useJournal(j)`
  ## or by direct assignment. fresco is currently single-threaded
  ## (one chronos dispatcher per thread), so a thread-local is the
  ## natural fit; if you spawn additional threads they each get
  ## their own `globalJournal` slot (initially nil). For multi-thread
  ## journal sharing, route appends through an explicit Journal
  ## reference rather than this variable.

proc newJournal*(): Journal = Journal(events: @[])

template journalEvent*(body: untyped) =
  ## Write a journal event under the active scope's identity, then
  ## advance `currentScope.lastEventId` to the new event id. Silent
  ## no-op when no journal is installed. Failures during append are
  ## swallowed — the journal is an audit trail, not a critical path.
  ##
  ## Inside `body`, three names are `{.inject.}`'d into scope:
  ##   `jrnl`      — the active journal (non-nil)
  ##   `taskTid`   — current scope's TaskId, or RootTask if no scope
  ##   `parentEvt` — current scope's lastEventId, or NoEvent if no scope
  ##
  ## (An internal `id` let-binding holds the returned EventId for the
  ## post-body lastEventId advancement. It's scoped to the template
  ## body and not visible to callers.)
  ##
  ## All three names are chosen to be collision-resistant: `jrnl` and
  ## `taskTid` rather than the obvious `j` and `tid` because the latter
  ## are common throwaway / loop-variable names. `parentEvt` rather
  ## than `p` for the same reason.
  ##
  ## `body` must evaluate to an `EventId` (typically a `jrnl.logXxx`
  ## call). Usage:
  ##
  ##   journalEvent:
  ##     jrnl.logTaskSpawned(taskTid, parentEvt, name, "")
  ##
  ## Replaces the 5-line `if globalJournal != nil: ...` boilerplate
  ## previously hand-rolled at every journal call site.
  if globalJournal != nil:
    let jrnl {.inject.} = globalJournal
    let taskTid {.inject.} = if currentScope != nil: currentScope.taskId else: RootTask
    let parentEvt {.inject.} = if currentScope != nil: currentScope.lastEventId else: NoEvent
    try:
      # Internal binding for the returned EventId. Prefixed to avoid
      # shadowing a caller's local `id` variable.
      let frescoEvtId = body
      if currentScope != nil: currentScope.lastEventId = frescoEvtId
    except CatchableError: discard

template journalEventOnScope*(scope: Scope, body: untyped) =
  ## Like `journalEvent` but attributes the event to a specific scope
  ## rather than `currentScope`. Used in callback sites where the
  ## dispatcher's `currentScope` is unrelated to the event's logical
  ## owner — e.g. `wireLifecycle`'s future-completion callback (uses
  ## the captured task's scope), the `spawn` template's pre-await
  ## logTaskSpawned, and `parallel:`'s concurrent-sibling cascade.
  ##
  ## Inside `body`, the same three names are injected as `journalEvent`:
  ##   `jrnl`      — the active journal (non-nil)
  ##   `taskTid`   — `scope.taskId` (or RootTask if scope is nil)
  ##   `parentEvt` — `scope.lastEventId` (or NoEvent if scope is nil)
  ##
  ## Advances `scope.lastEventId` to the new event id, NOT
  ## `currentScope.lastEventId`. Silent no-op without a journal;
  ## CatchableError from the log call is swallowed.
  if globalJournal != nil:
    let jrnl {.inject.} = globalJournal
    let taskTid {.inject.} = if scope != nil: scope.taskId else: RootTask
    let parentEvt {.inject.} = if scope != nil: scope.lastEventId else: NoEvent
    try:
      let frescoEvtId = body
      if scope != nil: scope.lastEventId = frescoEvtId
    except CatchableError: discard

proc useJournal*(j: Journal = nil): Journal =
  ## Install or reuse the process-wide journal. Semantics:
  ##
  ## - `useJournal(myJournal)` — always replaces the current journal
  ##   with `myJournal` and returns it.
  ## - `useJournal()` — if a journal is already installed, returns it
  ##   unchanged; otherwise creates a fresh in-memory `newJournal()`.
  ##
  ## Tests that want a fresh journal per case must call `resetJournal()`
  ## first (or assign `globalJournal = newJournal()` directly) — the
  ## no-arg form intentionally reuses an existing journal so library
  ## code can call it lazily without clobbering a host-installed one.
  if j != nil:
    globalJournal = j
  elif globalJournal == nil:
    globalJournal = newJournal()
  result = globalJournal

proc resetJournal*() =
  ## Clear the active journal (`globalJournal = nil`). Tests call this
  ## between cases so events from a prior test don't bleed into the
  ## next when subsequent code calls `useJournal()` with no arg. Also
  ## useful for embedding hosts that want to discard accumulated
  ## history and start fresh — calling `useJournal(newJournal())` is
  ## equivalent and more explicit when you want a specific instance.
  globalJournal = nil

# --- Append helpers ------------------------------------------------------

proc baseEvent(kind: EventKind, taskId: TaskId, parentId: EventId): Event =
  Event(
    id: EventId.fresh(),
    mono: Moment.now(),
    wall: getTime(),
    taskId: taskId,
    parentId: parentId,
    kind: kind)

proc append*(j: Journal, ev: sink Event): EventId =
  ## Append a pre-built event. Returns its id (for use as a future
  ## event's `parentId`).
  j.events.add ev
  result = j.events[^1].id
  j.onPersist(j.events[^1])

proc logTaskSpawned*(j: Journal, taskId: TaskId, parentId: EventId,
                    name = "", typeName = ""): EventId =
  var ev = baseEvent(ekTaskSpawned, taskId, parentId)
  ev.spawnedName = name
  ev.spawnedType = typeName
  j.append(ev)

proc logTaskCompleted*(j: Journal, taskId: TaskId,
                       parentId: EventId): EventId =
  j.append(baseEvent(ekTaskCompleted, taskId, parentId))

proc logTaskFailed*(j: Journal, taskId: TaskId, parentId: EventId,
                    msg, typeName: string): EventId =
  var ev = baseEvent(ekTaskFailed, taskId, parentId)
  ev.failureMsg = msg
  ev.failureType = typeName
  j.append(ev)

proc logTaskCancelled*(j: Journal, taskId: TaskId, parentId: EventId,
                       reason = ""): EventId =
  var ev = baseEvent(ekTaskCancelled, taskId, parentId)
  ev.cancelReason = reason
  j.append(ev)

proc logSignalWrite*(j: Journal, taskId: TaskId, parentId: EventId,
                    label, valueRepr: string): EventId =
  var ev = baseEvent(ekSignalWrite, taskId, parentId)
  ev.signalLabel = label
  ev.writeRepr = valueRepr
  j.append(ev)

proc logSignalRestored*(j: Journal, taskId: TaskId, parentId: EventId,
                       label, valueRepr: string,
                       fromTaskId: TaskId): EventId =
  ## Record an `orReplayJournal`-driven state restoration. `taskId` is
  ## the new task receiving the restored value; `fromTaskId` is the
  ## prior task whose `ekSignalWrite` was replayed. Audit trail —
  ## the value itself also lands in the journal via the new task's
  ## subsequent `ekSignalWrite` calls; this event distinguishes
  ## "restored from prior" from "freshly set."
  var ev = baseEvent(ekSignalRestored, taskId, parentId)
  ev.restoredLabel = label
  ev.restoredRepr = valueRepr
  ev.restoredFromTaskId = fromTaskId
  j.append(ev)

proc logCollectionDelta*(j: Journal, taskId: TaskId, parentId: EventId,
                         label, op: string, idx: int, repr: string): EventId =
  ## Record one CollectionSignal mutation. `op` is one of "insert" /
  ## "remove" / "update" / "clear" / "replace". `idx` is -1 for the
  ## whole-collection ops (clear, replace). `repr` carries the new
  ## value's repr for insert/update, the new length (as string) for
  ## replace, and empty for remove/clear.
  ##
  ## Reconstruction of collection state from these deltas requires
  ## either replaying from initial state or interleaving snapshots —
  ## v2.4+ may add a snapshot event variant.
  var ev = baseEvent(ekCollectionDelta, taskId, parentId)
  ev.collectionLabel = label
  ev.collectionOp = op
  ev.collectionIdx = idx
  ev.collectionRepr = repr
  j.append(ev)

proc logCollectionRollback*(j: Journal, taskId: TaskId, parentId: EventId,
                            label: string, count: int, opsRepr: string): EventId =
  ## Record a single speculative rollback of one collection. `count`
  ## is the number of inverse ops applied; `opsRepr` is a compact
  ## `;`-joined repr per op (see `collection.nim` for the format) — enough
  ## for forward replay without journaling each inverse as its own
  ## `ekCollectionDelta`. Distinguishes "user mutated then rolled back"
  ## from "user did N successive forward mutations" in the audit trail.
  var ev = baseEvent(ekCollectionRollback, taskId, parentId)
  ev.rollbackLabel = label
  ev.rollbackCount = count
  ev.rollbackOpsRepr = opsRepr
  j.append(ev)

proc logKeyReceived*(j: Journal, taskId: TaskId, parentId: EventId,
                     summary: string): EventId =
  var ev = baseEvent(ekKeyReceived, taskId, parentId)
  ev.keySummary = summary
  j.append(ev)

proc logKeyConsumed*(j: Journal, taskId: TaskId, parentId: EventId,
                     summary: string): EventId =
  var ev = baseEvent(ekKeyConsumed, taskId, parentId)
  ev.keySummary = summary
  j.append(ev)

proc logSupervisorRestart*(j: Journal, taskId: TaskId, parentId: EventId,
                           name: string, generation: int): EventId =
  var ev = baseEvent(ekSupervisorRestart, taskId, parentId)
  ev.restartName = name
  ev.generation = generation
  j.append(ev)

proc logSupervisorEscalate*(j: Journal, taskId: TaskId, parentId: EventId,
                            name, reason: string): EventId =
  var ev = baseEvent(ekSupervisorEscalate, taskId, parentId)
  ev.escalateName = name
  ev.escalateReason = reason
  j.append(ev)

proc logSupervisorTerminate*(j: Journal, taskId: TaskId, parentId: EventId,
                             name: string): EventId =
  var ev = baseEvent(ekSupervisorTerminate, taskId, parentId)
  ev.terminateName = name
  j.append(ev)

# --- Query API -----------------------------------------------------------

proc len*(j: Journal): int = j.events.len
proc `[]`*(j: Journal, i: int): Event = j.events[i]

iterator items*(j: Journal): Event =
  for e in j.events: yield e

proc byTask*(j: Journal, taskId: TaskId): seq[Event] =
  j.events.filterIt(it.taskId == taskId)

proc byKind*(j: Journal, kind: EventKind): seq[Event] =
  j.events.filterIt(it.kind == kind)

proc find*(j: Journal, id: EventId): Event =
  ## Linear scan for the event with the given id. Raises `KeyError`
  ## if no event matches — callers walking a known-valid chain (e.g.
  ## `ancestors`) catch this to terminate gracefully when a parent
  ## event has been skipped during persistent-journal load.
  for e in j.events:
    if e.id == id: return e
  raise newException(KeyError, "no event with id " & $id)

proc lastWritesByLabel*(j: Journal, taskId: TaskId): Table[string, Event] =
  ## For a given task, return the most-recent `ekSignalWrite` event per
  ## signal label. Useful for state restoration: walk this table and
  ## re-apply each entry's `writeRepr` to a freshly-declared signal of
  ## the same label.
  ##
  ## Signals declared without a label all share the empty-string key,
  ## so they're excluded from projection — restoring them would just
  ## clobber each other on every replay. Label your signals if you
  ## want them restorable.
  ##
  ## O(N) over the journal in the worst case, but a reverse scan with
  ## a seen-set short-circuits per label so the common case (where
  ## the task wrote each label only a handful of times near the end
  ## of the log) is effectively O(labels). For very long sessions
  ## that matter, consider the per-task index work tracked at #34.
  for i in countdown(j.events.high, 0):
    let ev = j.events[i]
    if ev.taskId == taskId and ev.kind == ekSignalWrite and
       ev.signalLabel.len > 0 and ev.signalLabel notin result:
      result[ev.signalLabel] = ev

# --- Bitemporal queries --------------------------------------------------

proc eventsBefore*(j: Journal, cutoff: EventId): seq[Event] =
  ## Every event with id <= cutoff, in original order. The cursor for
  ## time-warp UIs: pass an event id to "see what happened up to here."
  for e in j.events:
    if uint64(e.id) <= uint64(cutoff): result.add e

proc eventsBetween*(j: Journal, loWall, hiWall: Time): seq[Event] =
  ## Every event whose wall-clock timestamp falls in [loWall, hiWall].
  for e in j.events:
    if e.wall >= loWall and e.wall <= hiWall: result.add e

proc stateAt*(j: Journal, cutoff: EventId,
              taskId: TaskId = RootTask): Table[string, string] =
  ## Project signal state at `cutoff` for the given task. Returns
  ## a Table[label, writeRepr] — the most-recent value of each labeled
  ## signal among `ekSignalWrite` events with id <= cutoff for taskId.
  ## Unlabeled writes (`signalLabel == ""`) are excluded — see
  ## `lastWritesByLabel` for the rationale.
  ##
  ## **Multi-snapshot routing**: if the journal has any snapshots,
  ## find the largest one with `atEventId ≤ cutoff` (binary search),
  ## seed `result` from its `state`, and overlay only the events
  ## from that snapshot's atEventId upward. If `cutoff` is below the
  ## earliest snapshot, return that snapshot's state alone — granular
  ## history before it is gone (graceful degradation). Snapshots are
  ## task-agnostic, so when `taskId != RootTask` they're ignored.
  ##
  ## Pass `taskId = RootTask` to include all tasks (ignoring scope).
  var fromAfter = EventId(0)
  if taskId == RootTask and j.snapshots.len > 0:
    # Largest snapshot with atEventId ≤ cutoff. Linear scan; small
    # seq (a few dozen), not worth a binary search yet.
    var picked = -1
    for i in 0 ..< j.snapshots.len:
      if uint64(j.snapshots[i].atEventId) <= uint64(cutoff):
        picked = i
      else:
        break
    if picked >= 0:
      for label, repr in j.snapshots[picked].state:
        result[label] = repr
      fromAfter = j.snapshots[picked].atEventId
    else:
      # cutoff < earliest snapshot — return earliest as graceful floor.
      for label, repr in j.snapshots[0].state:
        result[label] = repr
      return
  for ev in j.events:
    if uint64(ev.id) <= uint64(fromAfter): continue
    if uint64(ev.id) > uint64(cutoff): break
    if ev.kind != ekSignalWrite: continue
    if ev.signalLabel.len == 0: continue
    if taskId == RootTask or ev.taskId == taskId:
      result[ev.signalLabel] = ev.writeRepr

proc snapshot*(j: Journal): Snapshot =
  ## Capture the current label-to-writeRepr state at the journal head.
  ## Equivalent to `j.stateAt(headId)` packaged with the head's id
  ## and wall-clock timestamp. Composes the oldest pre-existing
  ## snapshot (if any) with all subsequent events.
  result.state = initTable[string, string]()
  if j.snapshots.len > 0:
    for label, repr in j.snapshots[^1].state:
      result.state[label] = repr
  for ev in j.events:
    if j.snapshots.len > 0 and
       uint64(ev.id) <= uint64(j.snapshots[^1].atEventId): continue
    if ev.kind == ekSignalWrite and ev.signalLabel.len > 0:
      result.state[ev.signalLabel] = ev.writeRepr
  if j.events.len > 0:
    result.atEventId = j.events[^1].id
    result.atWall = j.events[^1].wall
  elif j.snapshots.len > 0:
    result.atEventId = j.snapshots[^1].atEventId
    result.atWall = j.snapshots[^1].atWall

proc addSnapshot*(j: Journal): Snapshot =
  ## Capture the current head state as a checkpoint and append it
  ## to `j.snapshots`. Idempotent at the same head: a snapshot
  ## whose `atEventId` equals the latest already-stored snapshot's
  ## `atEventId` is not duplicated — the existing snapshot is
  ## returned.
  ##
  ## Used both by callers wanting a fast projection index at a
  ## specific point (devtools time-warp) and by the retention
  ## policy machinery (see `applyRetention`).
  result = j.snapshot()
  if j.snapshots.len > 0 and
     j.snapshots[^1].atEventId == result.atEventId:
    return j.snapshots[^1]
  j.snapshots.add result
  j.onSnapshotAppended(result)

method compactBefore*(j: Journal, cutoff: EventId)
                     {.base, gcsafe, raises: [].} =
  ## Fold events with id ≤ `cutoff` into a single base snapshot, drop
  ## those events, and **collapse any pre-cutoff snapshots into the
  ## base** (single-base-post-compaction semantics).
  ##
  ## After this call: `j.snapshots[0]` is the base at `cutoff`,
  ## containing every label's last write up to `cutoff`. Snapshots
  ## that had `atEventId > cutoff` are preserved (they index
  ## still-live events). Per-event history at id ≤ cutoff is lost
  ## — `eventsBefore(id ≤ cutoff)` returns nothing.
  ##
  ## See also: `promoteBefore` (drops events but **keeps** pre-cutoff
  ## snapshots, so multi-snapshot history through the cutoff is
  ## preserved for fast projection at intermediate historical points).
  ##
  ## The PersistentJournal override additionally rewrites the on-disk
  ## file atomically.
  var newBase = Snapshot(state: initTable[string, string](),
                         atEventId: cutoff)
  # Seed with the latest pre-cutoff snapshot's state (if any).
  for s in j.snapshots:
    if uint64(s.atEventId) <= uint64(cutoff):
      newBase.atWall = s.atWall
      for label, repr in s.state:
        newBase.state[label] = repr
    else: break
  # Overlay pre-cutoff events.
  var keptEvents: seq[Event] = @[]
  for ev in j.events:
    if uint64(ev.id) <= uint64(cutoff):
      if ev.kind == ekSignalWrite and ev.signalLabel.len > 0:
        newBase.state[ev.signalLabel] = ev.writeRepr
      if ev.wall > newBase.atWall: newBase.atWall = ev.wall
    else:
      keptEvents.add ev
  # Keep only post-cutoff snapshots.
  var keptSnaps: seq[Snapshot] = @[newBase]
  for s in j.snapshots:
    if uint64(s.atEventId) > uint64(cutoff): keptSnaps.add s
  j.snapshots = keptSnaps
  j.events = keptEvents

proc promoteBefore*(j: Journal, cutoff: EventId) =
  ## Drop events with id ≤ `cutoff` BUT preserve every snapshot
  ## whose `atEventId` ≤ `cutoff`. This is the "promote to archive
  ## tier" primitive: granular event history below the cutoff is
  ## reclaimed, but multi-snapshot projection routing through the
  ## cutoff continues to work — `stateAt(midpoint)` for any
  ## midpoint at a preserved snapshot's id still answers correctly.
  ##
  ## Distinguishing from `compactBefore`: compactBefore collapses
  ## pre-cutoff snapshots to one base, sacrificing intermediate-point
  ## projection precision for a smaller snapshot footprint. Choose
  ## based on whether intermediate projection precision or snapshot
  ## storage matters more.
  ##
  ## If no snapshot exists at-or-below `cutoff`, this auto-captures
  ## one at the largest event id ≤ cutoff so post-promotion
  ## `stateAt(cutoff)` remains correct.
  var hasFloorSnapshot = false
  for s in j.snapshots:
    if uint64(s.atEventId) <= uint64(cutoff):
      hasFloorSnapshot = true
      break
  if not hasFloorSnapshot:
    # Take a synthetic floor snapshot at the largest event id ≤ cutoff.
    var floorId = EventId(0)
    var floorWall: Time
    var state = initTable[string, string]()
    for ev in j.events:
      if uint64(ev.id) > uint64(cutoff): break
      if ev.kind == ekSignalWrite and ev.signalLabel.len > 0:
        state[ev.signalLabel] = ev.writeRepr
      floorId = ev.id
      floorWall = ev.wall
    if uint64(floorId) > 0:
      let floor = Snapshot(atEventId: floorId, atWall: floorWall, state: state)
      # Insert sorted.
      var inserted = false
      var newSnaps: seq[Snapshot] = @[]
      for s in j.snapshots:
        if not inserted and uint64(s.atEventId) > uint64(floorId):
          newSnaps.add floor
          inserted = true
        newSnaps.add s
      if not inserted: newSnaps.add floor
      j.snapshots = newSnaps
  # Drop events ≤ cutoff.
  var keptEvents: seq[Event] = @[]
  for ev in j.events:
    if uint64(ev.id) > uint64(cutoff): keptEvents.add ev
  j.events = keptEvents

type
  RetentionPolicy* = object
    ## High-level retention configuration applied by
    ## `applyRetention(j, policy)`. All knobs are count-based (event
    ## or snapshot counts, not wall-clock); a time-based knob would
    ## be a follow-up.
    snapshotEvery*: int
      ## Auto-snapshot once `events.len mod snapshotEvery == 0` and
      ## a snapshot hasn't already been taken at the current head.
      ## Set to a large number (or `int.high`) to disable.
    keepEvents*: int
      ## When `events.len > keepEvents`, drop events older than
      ## (head - keepEvents) via `promoteBefore` — multi-snapshot
      ## projection precision through the cutoff is preserved.
    coarsenAfter*: int
      ## When `snapshots.len > coarsenAfter`, halve the density of
      ## the older half via `coarsen(... keepEvery = 2)`. Repeated
      ## applications cascade the density toward log scale —
      ## the "ladder" behavior.

proc coarsen*(j: Journal, atIdRange: HSlice[EventId, EventId], keepEvery: int) =
  ## Within the closed event-id range, keep every Nth snapshot in
  ## index order; drop the rest. `keepEvery == 1` is a no-op;
  ## `keepEvery == 2` halves density; etc. Used by `applyRetention`
  ## to demote a tier (reduce its snapshot count) once it grows
  ## beyond its bound.
  ##
  ## Snapshots outside the range are untouched. The first snapshot
  ## in the range is always kept (regardless of `keepEvery`) so that
  ## projection routing past the range still has a starting point.
  if keepEvery <= 1: return
  var keptSnaps: seq[Snapshot] = @[]
  var inRangeCount = 0
  for s in j.snapshots:
    let inRange = uint64(s.atEventId) >= uint64(atIdRange.a) and
                  uint64(s.atEventId) <= uint64(atIdRange.b)
    if inRange:
      if inRangeCount mod keepEvery == 0:
        keptSnaps.add s
      inc inRangeCount
    else:
      keptSnaps.add s
  j.snapshots = keptSnaps

proc applyRetention*(j: Journal, policy: RetentionPolicy) =
  ## Apply the retention policy. Steps, in order:
  ##
  ## 1. **Auto-snapshot**: if `events.len > 0` and
  ##    `events.len mod snapshotEvery == 0`, call `addSnapshot()`
  ##    (idempotent at the current head, so calling on the same head
  ##    repeatedly is safe).
  ## 2. **Promote**: if `events.len > keepEvents`, call
  ##    `promoteBefore(head_id - keepEvents)`. Drops old events
  ##    while preserving every snapshot through the cutoff.
  ## 3. **Coarsen**: if `snapshots.len > coarsenAfter`, halve the
  ##    density of the older half via `coarsen(... keepEvery = 2)`.
  ##    Each successive application coarsens that range further,
  ##    yielding a log-scale ladder over many invocations.
  ##
  ## Intended to be called periodically by the host (e.g., from an
  ## idle timer, after a batch of writes, or on a "compaction tick")
  ## rather than per-append. Auto-invocation on append would add
  ## overhead to the hot path and is left to the consumer.
  # 1. Auto-snapshot.
  if policy.snapshotEvery > 0 and j.events.len > 0 and
     j.events.len mod policy.snapshotEvery == 0:
    discard j.addSnapshot()
  # 2. Promote (drop old events).
  if policy.keepEvents > 0 and j.events.len > policy.keepEvents:
    let dropCount = j.events.len - policy.keepEvents
    let cutoffId = j.events[dropCount - 1].id
    j.promoteBefore(cutoffId)
  # 3. Coarsen older half.
  if policy.coarsenAfter > 0 and j.snapshots.len > policy.coarsenAfter:
    let half = j.snapshots.len div 2
    if half >= 2:
      let loId = j.snapshots[0].atEventId
      let hiId = j.snapshots[half - 1].atEventId
      j.coarsen(loId .. hiId, keepEvery = 2)

proc stateAtTime*(j: Journal, wall: Time,
                  taskId: TaskId = RootTask): Table[string, string] =
  ## Like `stateAt` but cuts at wall-clock `wall` instead of an event id.
  ## Unlabeled writes are excluded (see `lastWritesByLabel`).
  ##
  ## Full-scan rather than early-break on `ev.wall > wall`: wall-clock
  ## time isn't monotone (NTP adjustments, DST, leap seconds can cause
  ## `getTime()` to go backwards), so a single regressed event in the
  ## middle of the log would silently truncate projection. The last-
  ## write-wins semantics still rely on monotone event-id append order,
  ## which we have unconditionally.
  for ev in j.events:
    if ev.wall > wall: continue
    if ev.kind != ekSignalWrite: continue
    if ev.signalLabel.len == 0: continue
    if taskId == RootTask or ev.taskId == taskId:
      result[ev.signalLabel] = ev.writeRepr

proc ancestors*(j: Journal, id: EventId): seq[Event] =
  ## Walk the causal chain from `id` back to its root. The returned
  ## sequence is innermost-first (start, then parent, then grandparent…)
  ## and ends when an event with parentId == NoEvent is reached.
  ##
  ## Stops gracefully if a parent event is missing — this happens when
  ## a persistent journal load skipped schema-mismatched lines whose
  ## ids are referenced by surviving events' parentIds. Walking is
  ## best-effort in that scenario rather than crashing on KeyError.
  var cursor = id
  while cursor != NoEvent:
    var e: Event
    try: e = j.find(cursor)
    except KeyError: break
    result.add e
    cursor = e.parentId
