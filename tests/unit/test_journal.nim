import std/unittest
import chronos
import fresco/journal/events
import fresco/journal/log

suite "journal: id generators":

  test "TaskId and EventId are independently monotonic":
    let t1 = TaskId.fresh()
    let t2 = TaskId.fresh()
    let e1 = EventId.fresh()
    let e2 = EventId.fresh()
    check $t1 != $t2
    check $e1 != $e2
    check t1 != t2
    check e1 != e2

suite "journal: append + query":

  test "append returns the new event's id":
    let j = newJournal()
    let id = j.logTaskSpawned(TaskId.fresh(), NoEvent, "demo", "demoProc")
    check j.len == 1
    check j[0].id == id
    check j[0].kind == ekTaskSpawned
    check j[0].spawnedName == "demo"

  test "byTask returns only events for that task":
    let j = newJournal()
    let tA = TaskId.fresh()
    let tB = TaskId.fresh()
    discard j.logTaskSpawned(tA, NoEvent, "A", "")
    discard j.logTaskSpawned(tB, NoEvent, "B", "")
    discard j.logSignalWrite(tA, NoEvent, "count", "1")
    let a = j.byTask(tA)
    check a.len == 2
    for e in a: check e.taskId == tA

  test "byKind filters by event variant":
    let j = newJournal()
    let t = TaskId.fresh()
    discard j.logTaskSpawned(t, NoEvent)
    discard j.logSignalWrite(t, NoEvent, "x", "1")
    discard j.logSignalWrite(t, NoEvent, "y", "2")
    discard j.logTaskCompleted(t, NoEvent)
    check j.byKind(ekSignalWrite).len == 2
    check j.byKind(ekTaskSpawned).len == 1

  test "find by EventId":
    let j = newJournal()
    let t = TaskId.fresh()
    let id = j.logSignalWrite(t, NoEvent, "x", "42")
    let ev = j.find(id)
    check ev.id == id
    check ev.kind == ekSignalWrite
    check ev.writeRepr == "42"

  test "find raises KeyError on missing id":
    let j = newJournal()
    expect KeyError:
      discard j.find(EventId(99999))

suite "journal: causal ancestors":

  test "chain walks parent IDs back to the root":
    let j = newJournal()
    let t = TaskId.fresh()
    let a = j.logTaskSpawned(t, NoEvent, "root")
    let b = j.logSignalWrite(t, a, "x", "1")
    let c = j.logSignalWrite(t, b, "x", "2")
    let chain = j.ancestors(c)
    check chain.len == 3
    check chain[0].id == c
    check chain[1].id == b
    check chain[2].id == a
    check chain[^1].parentId == NoEvent

  test "ancestor of a root event is just itself":
    let j = newJournal()
    let id = j.logTaskSpawned(TaskId.fresh(), NoEvent, "solo")
    let chain = j.ancestors(id)
    check chain.len == 1
    check chain[0].id == id

suite "journal: timestamps":

  test "monotonic timestamp is non-decreasing across appends":
    let j = newJournal()
    let t = TaskId.fresh()
    discard j.logTaskSpawned(t, NoEvent)
    discard j.logSignalWrite(t, NoEvent, "x", "1")
    discard j.logSignalWrite(t, NoEvent, "x", "2")
    check j[0].mono <= j[1].mono
    check j[1].mono <= j[2].mono

  test "wall-clock timestamp is set":
    let j = newJournal()
    discard j.logTaskSpawned(TaskId.fresh(), NoEvent)
    # Wall clock is non-zero (set to getTime() which is always meaningful).
    check $j[0].wall != ""
