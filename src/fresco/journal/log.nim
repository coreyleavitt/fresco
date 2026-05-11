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
import ../reactive/scope

type
  Journal* = ref object of RootObj
    events*: seq[Event]

method onPersist*(j: Journal, e: Event) {.base, gcsafe, raises: [].} = discard
  ## Persistence hook fired after an event is appended. Default
  ## implementation does nothing; PersistentJournal overrides it to
  ## flush the event to disk.

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
  ## Pass `taskId = RootTask` to include all tasks (ignoring scope).
  for ev in j.events:
    if uint64(ev.id) > uint64(cutoff): break
    if ev.kind != ekSignalWrite: continue
    if ev.signalLabel.len == 0: continue
    if taskId == RootTask or ev.taskId == taskId:
      result[ev.signalLabel] = ev.writeRepr

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
