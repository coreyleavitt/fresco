## Journal integration: task lifecycle events flow through the log.

import std/unittest
import chronos
import fresco/journal/events
import fresco/journal/log
import fresco/reactive/scope
import fresco/reactive/signal
import fresco/task/core

proc tick(): Future[void] {.async: (raises: [CancelledError]).} =
  await sleepAsync(0.milliseconds)

suite "journal: task lifecycle":

  setup:
    globalJournal = newJournal()

  test "spawn writes a TaskSpawned event":
    proc body() {.async: (raises: [Exception]).} =
      proc work() {.async.} = await sleepAsync(2.milliseconds)
      let m = spawn work()
      await m.wait()
      let spawned = globalJournal.byKind(ekTaskSpawned)
      check spawned.len == 1
      check spawned[0].taskId == m.scope.taskId
    waitFor body()

  test "clean completion writes a TaskCompleted event":
    proc body() {.async: (raises: [Exception]).} =
      proc work() {.async.} = await sleepAsync(2.milliseconds)
      let m = spawn work()
      await m.wait()
      let done = globalJournal.byKind(ekTaskCompleted)
      check done.len == 1
      check done[0].taskId == m.scope.taskId
    waitFor body()

  test "failure writes a TaskFailed event with exception details":
    proc body() {.async: (raises: [Exception]).} =
      proc broken() {.async.} =
        await sleepAsync(1.milliseconds)
        raise newException(ValueError, "boom")
      let m = spawn broken()
      try: await m.wait()
      except ValueError: discard
      let failed = globalJournal.byKind(ekTaskFailed)
      check failed.len == 1
      check failed[0].failureMsg == "boom"
      check failed[0].failureType == "ValueError"
    waitFor body()

  test "cancellation writes a TaskCancelled event":
    proc body() {.async: (raises: [Exception]).} =
      proc work() {.async.} = await sleepAsync(500.milliseconds)
      let m = spawn work()
      await tick()
      m.cancel()
      await tick(); await tick()
      let cancelled = globalJournal.byKind(ekTaskCancelled)
      check cancelled.len == 1
    waitFor body()

  test "withScope after an await re-binds context (documented v3 workaround)":
    # Until v3 ships coroutine-context isolation (#37), user code that
    # needs context after an await must manually re-bind via the Mount's
    # scope. Verify that pattern produces correct journal attribution.
    proc body() {.async: (raises: [Exception]).} =
      proc work() {.async.} =
        let myScope = currentScope            # capture pre-await
        await sleepAsync(5.milliseconds)
        withScope(myScope):                   # re-bind post-await
          let n = signal(0, label = "n")
          n.set(42)
      let m = spawn work()
      await m.wait()
      let writes = globalJournal.byKind(ekStateWrite)
      check writes.len == 1
      check writes[0].taskId == m.scope.taskId   # correct attribution
    waitFor body()

  test "parent's spawn cause is parent's lastEventId":
    proc body() {.async: (raises: [Exception]).} =
      proc grandchild() {.async.} = await sleepAsync(2.milliseconds)
      proc child() {.async.} =
        let g = spawn grandchild()
        await g.wait()
      let c = spawn child()
      await c.wait()

      # The spawn that started grandchild should have a parentId that
      # points back to the spawn event that started child.
      let spawns = globalJournal.byKind(ekTaskSpawned)
      check spawns.len == 2
      let childSpawn      = spawns[0]
      let grandchildSpawn = spawns[1]
      check grandchildSpawn.parentId == childSpawn.id
    waitFor body()
