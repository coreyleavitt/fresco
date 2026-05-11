## Typed event variants for the reactive journal.
##
## Every observable system action — task lifecycle, state mutation,
## key delivery, supervisor decision — is journaled as one of these
## events. Together they form the single substrate over which
## bitemporal projection (v2.2), capability inference (v2.4), and
## time-warp debugging operate.
##
## Each event carries:
##   - `id`         monotonically-increasing event sequence number
##   - `mono`       monotonic timestamp from chronos
##   - `wall`       wall-clock timestamp for human display
##   - `taskId`     the task scope the event belongs to (0 = root)
##   - `parentId`   causal parent event id (0 if no parent)
##   - typed payload by kind

import std/times
import chronos

type
  TaskId* = distinct uint32
  EventId* = distinct uint64

  EventKind* = enum
    ekTaskSpawned
    ekTaskCompleted
    ekTaskFailed
    ekTaskCancelled
    ekSignalWrite
    ekKeyReceived
    ekKeyConsumed
    ekSupervisorRestart
    ekSupervisorEscalate
    ekSupervisorTerminate

  Event* = object
    id*:        EventId
    mono*:      Moment
    wall*:      Time
    taskId*:    TaskId
    parentId*:  EventId
    case kind*: EventKind
    of ekTaskSpawned:
      spawnedName*:    string         # human label (or "")
      spawnedType*:    string         # name of the async proc, when available
    of ekTaskCompleted:
      discard
    of ekTaskFailed:
      failureMsg*:     string
      failureType*:    string         # exception type name
    of ekTaskCancelled:
      cancelReason*:   string
    of ekSignalWrite:
      signalLabel*:    string         # signal identifier (or "")
      writeRepr*:      string         # repr-style value
    of ekKeyReceived, ekKeyConsumed:
      keySummary*:     string         # rendered KeyEvent
    of ekSupervisorRestart:
      restartName*:    string
      generation*:     int
    of ekSupervisorEscalate:
      escalateName*:   string
      escalateReason*: string
    of ekSupervisorTerminate:
      terminateName*:       string

# --- Distinct-type plumbing ----------------------------------------------

proc `==`*(a, b: TaskId): bool {.borrow.}
proc `==`*(a, b: EventId): bool {.borrow.}
proc `$`*(t: TaskId): string {.borrow.}
proc `$`*(e: EventId): string {.borrow.}
proc hash*(t: TaskId): int {.inline.} = int(uint32(t))
proc hash*(e: EventId): int {.inline.} = int(uint64(e))

const
  RootTask*: TaskId = TaskId(0)
  NoEvent*:  EventId = EventId(0)

# --- ID generators -------------------------------------------------------

var nextEventId {.threadvar.}: uint64
var nextTaskId  {.threadvar.}: uint32

proc fresh*(_: typedesc[EventId]): EventId =
  inc nextEventId
  EventId(nextEventId)

proc fresh*(_: typedesc[TaskId]): TaskId =
  inc nextTaskId
  TaskId(nextTaskId)

proc bumpFresh*(_: typedesc[EventId], floor: EventId) =
  ## Ensure the next `EventId.fresh()` returns at least `floor + 1`.
  ## Used by the persistence layer to continue id allocation past
  ## the maximum seen in a loaded journal.
  if uint64(floor) > nextEventId: nextEventId = uint64(floor)

proc bumpFresh*(_: typedesc[TaskId], floor: TaskId) =
  if uint32(floor) > nextTaskId: nextTaskId = uint32(floor)
