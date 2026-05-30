## Journal integration: signal writes flow through the log.

{.experimental: "callOperator".}

import std/unittest
import chronos
import intonaco/journal/events
import intonaco/journal/log
import intonaco/reactive

suite "journal: signal writes":

  setup:
    globalJournal = newJournal()

  teardown:
    resetJournal()

  test "signal.set writes a StateWrite event with label and repr":
    let count {.height: 0.} = signalC(0, label = "count")
    count.set(5)
    let writes = globalJournal.byKind(ekSignalWrite)
    check writes.len == 1
    check writes[0].signalLabel == "count"
    check writes[0].writeRepr == "5"

  test "state: block auto-labels signals from variable names":
    signals:
      countx = 0
      titlex = "hi"
    countx := 7
    titlex := "world"
    let writes = globalJournal.byKind(ekSignalWrite)
    check writes.len == 2
    var labels: seq[string] = @[]
    for w in writes: labels.add w.signalLabel
    check "countx" in labels
    check "titlex" in labels

  test "equal-write short-circuits do not journal":
    let x {.height: 0.} = signalC(42, label = "x")
    x.set(42)   # no change → no event
    x.set(7)    # change → 1 event
    x.set(7)    # no change → no event
    check globalJournal.byKind(ekSignalWrite).len == 1

  test "writes inside a spawned task get the task's taskId":
    proc body() {.async: (raises: [Exception]).} =
      proc work() {.async.} =
        let n {.height: 0.} = signalC(0, label = "n")
        n.set(1)
        n.set(2)
      let m = spawn work()
      await m.wait()
      let writes = globalJournal.byKind(ekSignalWrite)
      check writes.len == 2
      for w in writes:
        check w.taskId == m.scope.taskId
    waitFor body()

  test "successive writes from the same task chain causally":
    proc body() {.async: (raises: [Exception]).} =
      proc work() {.async.} =
        let n {.height: 0.} = signalC(0, label = "n")
        n.set(1)
        n.set(2)
        n.set(3)
      let m = spawn work()
      await m.wait()
      let writes = globalJournal.byKind(ekSignalWrite)
      check writes.len == 3
      check writes[1].parentId == writes[0].id
      check writes[2].parentId == writes[1].id
    waitFor body()
