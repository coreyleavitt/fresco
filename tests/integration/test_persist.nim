## On-disk journal persistence + crash recovery.

import std/[unittest, os, times, json]
import intonaco/journal/events
import intonaco/journal/log
import intonaco/journal/persist

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
      discard j.logSignalWrite(t, NoEvent, "count", "5")
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
    discard j.logSignalWrite(t, NoEvent, "x", "42")
    discard j.logCollectionDelta(t, NoEvent, "items", "insert", 0, "v")
    discard j.logCollectionRollback(t, NoEvent, "items", 2, "r:0;r:1")
    discard j.logKeyReceived(t, NoEvent, "Char(a)")
    discard j.logKeyConsumed(t, NoEvent, "Ctrl-q")
    discard j.logSupervisorRestart(t, NoEvent, "worker", 2)
    discard j.logSupervisorEscalate(t, NoEvent, "worker", "too many")
    discard j.logSupervisorTerminate(t, NoEvent, "worker")
    discard j.logSignalRestored(t, NoEvent, "count", "42", TaskId(99))
    close(j)

    let j2 = openJournal(path)
    check j2.events.len == 12
    let kinds = block:
      var s: seq[EventKind] = @[]
      for e in j2.events: s.add e.kind
      s
    check kinds == @[
      ekTaskSpawned, ekTaskCancelled, ekTaskFailed,
      ekSignalWrite, ekCollectionDelta, ekCollectionRollback,
      ekKeyReceived, ekKeyConsumed,
      ekSupervisorRestart, ekSupervisorEscalate, ekSupervisorTerminate,
      ekSignalRestored
    ]
    # Spot-check the rollback variant's payload survives.
    let rb = j2.events[5]
    check rb.rollbackLabel == "items"
    check rb.rollbackCount == 2
    check rb.rollbackOpsRepr == "r:0;r:1"
    # Spot-check the restored variant's payload survives.
    let rs = j2.events[11]
    check rs.restoredLabel == "count"
    check rs.restoredRepr == "42"
    check rs.restoredFromTaskId == TaskId(99)
    close(j2)

  test "corrupt line at EOF is skipped, prior events survive":
    let path = tempPath()
    defer: discard tryRemoveFile(path)

    block:
      let j = openJournal(path)
      let t = TaskId.fresh()
      discard j.logSignalWrite(t, NoEvent, "x", "1")
      discard j.logSignalWrite(t, NoEvent, "x", "2")
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
      discard j.logSignalWrite(t, NoEvent, "x", "1")
      discard j.logSignalWrite(t, NoEvent, "x", "2")
      close(j)

    let j2 = openJournal(path)
    let loadedMax = uint64(j2.events[^1].id)
    let next = EventId.fresh()
    check uint64(next) > loadedMax
    close(j2)

suite "persist: edge cases":

  test "openJournal with bare relative filename doesn't crash":
    # Previously: parentDir("journal.log") == "" → createDir("") raised.
    let cwd = getCurrentDir()
    let tmpdir = getTempDir() / ("fresco-bare-" & $getCurrentProcessId())
    createDir(tmpdir)
    defer: removeDir(tmpdir)
    setCurrentDir(tmpdir)
    defer: setCurrentDir(cwd)
    let j = openJournal("bare-name.log")
    close(j)
    check fileExists(tmpdir / "bare-name.log")

  test "schema-version mismatch lines are skipped, not crash":
    let path = tempPath()
    defer: discard tryRemoveFile(path)

    # Write a hand-crafted line with the wrong version.
    let f = open(path, fmWrite)
    f.writeLine("""{"v":999,"id":1,"wall":0,"taskId":0,"parentId":0,"kind":"ekTaskSpawned","spawnedName":"old","spawnedType":""}""")
    f.close()

    # openJournal must not raise; the mismatched entry is skipped.
    let j = openJournal(path)
    check j.events.len == 0
    close(j)

  test "fromJson directly raises JournalSchemaMismatch on bad version":
    # Round-7 L5: assert the exception type and field values rather
    # than only the "didn't crash" outcome of the openJournal path.
    let badNode = %* {"v": 999, "id": 1, "wall": 0, "taskId": 0,
                      "parentId": 0, "kind": "ekTaskSpawned",
                      "spawnedName": "x", "spawnedType": ""}
    var raised = false
    var foundV = 0
    try:
      discard fromJson(badNode)
    except JournalSchemaMismatch as e:
      raised = true
      foundV = e.foundVersion
    check raised
    check foundV == 999

  test "bumpAfterLoad is O(1) advance, not O(maxId)":
    # Previously: a high maxId would loop fresh() that many times,
    # potentially hanging startup. Just verify the load is fast and
    # the next fresh() exceeds the loaded max.
    let path = tempPath()
    defer: discard tryRemoveFile(path)

    block:
      let j = openJournal(path)
      let t = TaskId.fresh()
      # Burn a few thousand ids before our recorded event.
      for _ in 0 ..< 5000: discard EventId.fresh()
      discard j.logSignalWrite(t, NoEvent, "x", "high")
      close(j)

    let started = epochTime()
    let j2 = openJournal(path)
    let elapsed = epochTime() - started
    # Even with id ~5001, advance is constant-time — well under 1s.
    check elapsed < 0.5
    let next = EventId.fresh()
    check uint64(next) > uint64(j2.events[^1].id)
    close(j2)
