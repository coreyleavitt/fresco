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
import ./events
import ./log

const
  JournalSchemaVersion* = 1
    ## Bumped whenever the on-disk JSON shape changes incompatibly
    ## (new variant payload field rename, EventKind reorder, etc.).
    ## Each event line carries `v` = JournalSchemaVersion; openJournal
    ## skips lines whose schema doesn't match.

type
  JournalSchemaMismatch* = object of CatchableError
    foundVersion*: int
    expectedVersion*: int

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
  result["v"]        = %JournalSchemaVersion
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
  of ekSignalWrite:
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
    result["terminateName"] = %e.terminateName

proc parseKind(s: string): Option[EventKind] =
  for k in EventKind:
    if $k == s: return some(k)
  none(EventKind)

proc fromJson*(n: JsonNode): Option[Event] =
  if n.kind != JObject: return none(Event)
  # Lines missing `v` are pre-versioning (treat as v0 — rejected).
  let v = n{"v"}.getInt(0)
  if v != JournalSchemaVersion:
    var err = newException(JournalSchemaMismatch,
      "journal entry schema v" & $v & " incompatible with current v" &
      $JournalSchemaVersion)
    err.foundVersion = v
    err.expectedVersion = JournalSchemaVersion
    raise err
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
  of ekSignalWrite:
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
    e.terminateName = n{"terminateName"}.getStr("")
  some(e)

# --- File-backed Journal -------------------------------------------------

type
  PersistentJournal* = ref object of Journal
    path*: string
    file: File
    warnedWriteFailure: bool
      ## Set true after the first write failure so the stderr
      ## diagnostic doesn't spam every subsequent appended event.

proc openJournal*(path: string): PersistentJournal =
  ## Open (or create) an on-disk journal at `path`. If the file
  ## exists, replays its contents into the in-memory event log and
  ## bumps id generators. The returned journal appends every new
  ## event to the file as well as to memory.
  result = PersistentJournal(events: @[], path: path)
  # Ensure the parent directory exists *before* attempting to read
  # (lines() would raise IOError on a missing dir, and we want first-
  # time opens against fresh paths to succeed).
  let parent = parentDir(path)
  if parent.len > 0: createDir(parent)
  if fileExists(path):
    var schemaMismatchCount = 0
    try:
      for raw in lines(path):
        if raw.len == 0: continue
        let parsed =
          try: parseJson(raw)
          # Widen beyond JsonParsingError: malformed payloads can
          # surface as IOError/ValueError on some inputs. The contract
          # is "never crash openJournal on a corrupt line."
          except CatchableError: nil
        if parsed == nil: continue
        let ev =
          try: fromJson(parsed)
          except JournalSchemaMismatch:
            inc schemaMismatchCount
            none(Event)
        if ev.isSome: result.events.add ev.get
    except CatchableError:
      discard   # file vanished mid-read or similar — proceed with what we have
    if schemaMismatchCount > 0:
      try:
        stderr.writeLine("fresco: " & $schemaMismatchCount &
                         " journal entr" &
                         (if schemaMismatchCount == 1: "y" else: "ies") &
                         " skipped due to schema-version mismatch")
      except IOError: discard
    bumpAfterLoad(result)
  result.file = open(path, fmAppend)

proc close*(j: PersistentJournal) =
  if j.file != nil:
    j.file.close()
    j.file = nil

# --- Append hook ---------------------------------------------------------

method onPersist*(j: PersistentJournal, e: Event) {.gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    if j.file == nil: return
    try:
      j.file.write($e.toJson() & "\n")
      j.file.flushFile()
    except CatchableError as err:
      # First write failure: one-shot stderr diagnostic so the user
      # sees the journal stopped persisting. Subsequent failures swallow.
      if not j.warnedWriteFailure:
        j.warnedWriteFailure = true
        try:
          stderr.writeLine("fresco journal write failed (" &
                           $err.name & ": " & err.msg &
                           "); subsequent events will be lost")
        except IOError: discard
