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

import std/[times, sequtils]
import chronos
import ./events

type
  Journal* = ref object
    events*: seq[Event]

var globalJournal* {.threadvar.}: Journal
  ## Process-wide journal. `useJournal()` opens / installs one; tasks
  ## append to it via the helpers below.

proc newJournal*(): Journal = Journal(events: @[])

proc useJournal*(j: Journal = nil): Journal =
  ## Install `j` as the process-wide journal (creating one if nil).
  ## Returns the active journal so callers can hold a handle.
  if globalJournal == nil:
    globalJournal = if j != nil: j else: newJournal()
  result = globalJournal

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

proc logStateWrite*(j: Journal, taskId: TaskId, parentId: EventId,
                    label, valueRepr: string): EventId =
  var ev = baseEvent(ekStateWrite, taskId, parentId)
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
  ev.termName = name
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
  for e in j.events:
    if e.id == id: return e
  raise newException(KeyError, "no event with id " & $id)

proc ancestors*(j: Journal, id: EventId): seq[Event] =
  ## Walk the causal chain from `id` back to its root. The returned
  ## sequence is innermost-first (start, then parent, then grandparent…)
  ## and ends when an event with parentId == NoEvent is reached.
  var cursor = id
  while cursor != NoEvent:
    let e = j.find(cursor)
    result.add e
    cursor = e.parentId
