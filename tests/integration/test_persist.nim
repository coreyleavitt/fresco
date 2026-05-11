## On-disk journal persistence + crash recovery.

import std/[unittest, os, times]
import fresco/journal/events
import fresco/journal/log
import fresco/journal/persist

proc tempPath(): string =
  getTempDir() / ("fresco-journal-test-" & $getCurrentProcessId() & "-" &
                  $epochTime() & ".log")

suite "persist: round-trip":

  test "open new file, append events, reopen sees them all":
    let path = tempPath()
    defer: discard tryRemoveFile(path)

    block:
      let j = openJournal(path)
      let t = TaskId.fresh()
      discard j.logTaskSpawned(t, NoEvent, "boot", "")
      discard j.logStateWrite(t, NoEvent, "count", "5")
      discard j.logTaskCompleted(t, NoEvent)
      close(j)

    let j2 = openJournal(path)
    check j2.events.len == 3
    check j2.events[0].kind == ekTaskSpawned
    check j2.events[1].signalLabel == "count"
    check j2.events[2].kind == ekTaskCompleted
    close(j2)

  test "fromJson round-trips every variant":
    let path = tempPath()
    defer: discard tryRemoveFile(path)

    let j = openJournal(path)
    let t = TaskId.fresh()
    discard j.logTaskSpawned(t, NoEvent, "n", "T")
    discard j.logTaskCancelled(t, NoEvent, "user")
    discard j.logTaskFailed(t, NoEvent, "msg", "ValueError")
    discard j.logStateWrite(t, NoEvent, "x", "42")
    discard j.logKeyReceived(t, NoEvent, "Char(a)")
    discard j.logKeyConsumed(t, NoEvent, "Ctrl-q")
    discard j.logSupervisorRestart(t, NoEvent, "worker", 2)
    discard j.logSupervisorEscalate(t, NoEvent, "worker", "too many")
    discard j.logSupervisorTerminate(t, NoEvent, "worker")
    close(j)

    let j2 = openJournal(path)
    check j2.events.len == 9
    let kinds = block:
      var s: seq[EventKind] = @[]
      for e in j2.events: s.add e.kind
      s
    check kinds == @[
      ekTaskSpawned, ekTaskCancelled, ekTaskFailed,
      ekStateWrite, ekKeyReceived, ekKeyConsumed,
      ekSupervisorRestart, ekSupervisorEscalate, ekSupervisorTerminate
    ]
    close(j2)

  test "corrupt line at EOF is skipped, prior events survive":
    let path = tempPath()
    defer: discard tryRemoveFile(path)

    block:
      let j = openJournal(path)
      let t = TaskId.fresh()
      discard j.logStateWrite(t, NoEvent, "x", "1")
      discard j.logStateWrite(t, NoEvent, "x", "2")
      close(j)

    # Simulate a crashed half-write at end of file.
    let f = open(path, fmAppend)
    f.write("not-valid-json{partial\n")
    f.close()

    let j2 = openJournal(path)
    check j2.events.len == 2     # crashed last line skipped
    close(j2)

  test "id generators continue past loaded max":
    let path = tempPath()
    defer: discard tryRemoveFile(path)

    block:
      let j = openJournal(path)
      let t = TaskId.fresh()
      discard j.logStateWrite(t, NoEvent, "x", "1")
      discard j.logStateWrite(t, NoEvent, "x", "2")
      close(j)

    let j2 = openJournal(path)
    let loadedMax = uint64(j2.events[^1].id)
    let next = EventId.fresh()
    check uint64(next) > loadedMax
    close(j2)
