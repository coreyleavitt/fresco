## onRestart handler + lastWritesByLabel: scaffolding for state
## restoration across supervisor restarts.

{.experimental: "callOperator".}

import std/[unittest, tables]
import chronos
import fresco/journal/events
import fresco/journal/log
import fresco/reactive/scope
import fresco/reactive/signal
import fresco/task/core
import fresco/task/supervisor

suite "supervisor onRestart":

  setup:
    globalJournal = newJournal()

  test "onRestart fires before re-spawning, with previous taskId":
    proc body() {.async: (raises: [Exception]).} =
      var restartCallTids: seq[TaskId] = @[]
      var attempts = 0
      proc child(): Future[void] {.async.} =
        inc attempts
        await sleepAsync(1.milliseconds)
        if attempts < 3:
          raise newException(IOError, "again")

      let sup = newSupervisor(maxRestarts = 10, within = 1.seconds)
      sup.addChild("c", lcTransient, child,
        onRestart = proc(j: Journal, prev: TaskId) =
          restartCallTids.add prev)
      await sup.run()
      # 3 attempts → 2 restarts → 2 handler calls. Each prevTid is
      # the taskId of the previous (failed) child instance.
      check restartCallTids.len == 2
      check restartCallTids[0] != restartCallTids[1]
    waitFor body()

  test "lastWritesByLabel returns the most-recent state per signal":
    let t = TaskId.fresh()
    discard globalJournal.logTaskSpawned(t, NoEvent, "demo", "")
    discard globalJournal.logStateWrite(t, NoEvent, "count", "1")
    discard globalJournal.logStateWrite(t, NoEvent, "title", "hello")
    discard globalJournal.logStateWrite(t, NoEvent, "count", "2")
    discard globalJournal.logStateWrite(t, NoEvent, "count", "7")

    let table = globalJournal.lastWritesByLabel(t)
    check "count" in table
    check "title" in table
    check table["count"].writeRepr == "7"
    check table["title"].writeRepr == "hello"

  test "onRestart sees state writes from the previous task":
    proc body() {.async: (raises: [Exception]).} =
      var observedRepr: string = ""
      var attempts = 0
      proc child(): Future[void] {.async.} =
        inc attempts
        let count = signal(0, label = "count")
        count.set(attempts * 10)        # journaled
        await sleepAsync(1.milliseconds)
        if attempts < 2:
          raise newException(IOError, "again")

      let sup = newSupervisor(maxRestarts = 10, within = 1.seconds)
      sup.addChild("c", lcTransient, child,
        onRestart = proc(j: Journal, prev: TaskId) =
          let last = j.lastWritesByLabel(prev)
          if "count" in last:
            observedRepr = last["count"].writeRepr)
      await sup.run()
      check observedRepr == "10"        # first attempt wrote 10 before failing
    waitFor body()
