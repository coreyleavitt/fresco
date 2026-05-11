## Append-only on-disk journal — JSONL frames, one event per line.
##
##   let j = openJournal("$XDG_STATE_HOME/myapp/journal.log")
##   useJournal(j)                  # install as the global
##   # ... app runs; events stream to both memory and disk ...
##   close(j)
##
## On restart, `openJournal(path)` reads every line from the existing
## file, decodes each into an Event, populates the in-memory journal,
## and bumps the EventId / TaskId generators so new events continue
## monotonically. User code can then call `lastWritesByLabel` /
## `stateAt` to recover state from the prior session.
##
## Format: one JSON object per line. Lines that fail to parse are
## skipped (partial-write tolerance — a crashed write at end of file
## doesn't corrupt the rest).

import std/[json, options, os, times]
import chronos
import ./events
import ./log

# --- (Re-)bump the id generators after a load ----------------------------

proc bumpAfterLoad*(j: Journal) =
  ## Ensure new events allocated after loading don't collide with ids
  ## already in the journal. O(n) over events to find the max; O(1) to
  ## advance the id generators.
  var maxEvt = EventId(0)
  var maxTsk = TaskId(0)
  for e in j.events:
    if uint64(e.id) > uint64(maxEvt): maxEvt = e.id
    if uint32(e.taskId) > uint32(maxTsk): maxTsk = e.taskId
  EventId.bumpFresh(maxEvt)
  TaskId.bumpFresh(maxTsk)

# --- Serialization -------------------------------------------------------

proc toJson*(e: Event): JsonNode =
  result = newJObject()
  result["id"]       = %uint64(e.id)
  result["wall"]     = %e.wall.toUnixFloat()
  result["taskId"]   = %uint32(e.taskId)
  result["parentId"] = %uint64(e.parentId)
  result["kind"]     = %($e.kind)
  case e.kind
  of ekTaskSpawned:
    result["spawnedName"] = %e.spawnedName
    result["spawnedType"] = %e.spawnedType
  of ekTaskCompleted, ekTaskCancelled:
    if e.kind == ekTaskCancelled: result["cancelReason"] = %e.cancelReason
  of ekTaskFailed:
    result["failureMsg"]  = %e.failureMsg
    result["failureType"] = %e.failureType
  of ekStateWrite:
    result["signalLabel"] = %e.signalLabel
    result["writeRepr"]   = %e.writeRepr
  of ekKeyReceived, ekKeyConsumed:
    result["keySummary"]  = %e.keySummary
  of ekSupervisorRestart:
    result["restartName"] = %e.restartName
    result["generation"]  = %e.generation
  of ekSupervisorEscalate:
    result["escalateName"]   = %e.escalateName
    result["escalateReason"] = %e.escalateReason
  of ekSupervisorTerminate:
    result["termName"] = %e.termName

proc parseKind(s: string): Option[EventKind] =
  for k in EventKind:
    if $k == s: return some(k)
  none(EventKind)

proc fromJson*(n: JsonNode): Option[Event] =
  if n.kind != JObject: return none(Event)
  let kindStr = n{"kind"}.getStr("")
  let kindOpt = parseKind(kindStr)
  if kindOpt.isNone: return none(Event)
  var e = Event(kind: kindOpt.get)
  e.id       = EventId(n{"id"}.getInt(0).uint64)
  # `mono` is process-local; reloaded events have a default Moment.
  e.wall     = fromUnixFloat(n{"wall"}.getFloat(0))
  e.taskId   = TaskId(n{"taskId"}.getInt(0).uint32)
  e.parentId = EventId(n{"parentId"}.getInt(0).uint64)
  case e.kind
  of ekTaskSpawned:
    e.spawnedName = n{"spawnedName"}.getStr("")
    e.spawnedType = n{"spawnedType"}.getStr("")
  of ekTaskCompleted: discard
  of ekTaskCancelled:
    e.cancelReason = n{"cancelReason"}.getStr("")
  of ekTaskFailed:
    e.failureMsg  = n{"failureMsg"}.getStr("")
    e.failureType = n{"failureType"}.getStr("")
  of ekStateWrite:
    e.signalLabel = n{"signalLabel"}.getStr("")
    e.writeRepr   = n{"writeRepr"}.getStr("")
  of ekKeyReceived, ekKeyConsumed:
    e.keySummary = n{"keySummary"}.getStr("")
  of ekSupervisorRestart:
    e.restartName = n{"restartName"}.getStr("")
    e.generation  = n{"generation"}.getInt(0)
  of ekSupervisorEscalate:
    e.escalateName   = n{"escalateName"}.getStr("")
    e.escalateReason = n{"escalateReason"}.getStr("")
  of ekSupervisorTerminate:
    e.termName = n{"termName"}.getStr("")
  some(e)

# --- File-backed Journal -------------------------------------------------

type
  PersistentJournal* = ref object of Journal
    path*: string
    file*: File

proc openJournal*(path: string): PersistentJournal =
  ## Open (or create) an on-disk journal at `path`. If the file
  ## exists, replays its contents into the in-memory event log and
  ## bumps id generators. The returned journal appends every new
  ## event to the file as well as to memory.
  result = PersistentJournal(events: @[], path: path)
  if fileExists(path):
    for raw in lines(path):
      if raw.len == 0: continue
      let parsed =
        try: parseJson(raw)
        except JsonParsingError: nil
      if parsed == nil: continue
      let ev = fromJson(parsed)
      if ev.isSome: result.events.add ev.get
    bumpAfterLoad(result)
  let parent = parentDir(path)
  if parent.len > 0: createDir(parent)
  result.file = open(path, fmAppend)

proc close*(j: PersistentJournal) =
  if j.file != nil:
    j.file.close()
    j.file = nil

# --- Append hook ---------------------------------------------------------

method onPersist*(j: PersistentJournal, e: Event) {.gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    if j.file != nil:
      try:
        j.file.write($e.toJson() & "\n")
        j.file.flushFile()
      except Exception: discard
