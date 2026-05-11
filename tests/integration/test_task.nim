## Task primitive integration tests. Lives in tests/integration/ because
## it drives a real chronos dispatcher; the reactive primitives we
## already shipped are unit-tested separately.

import std/unittest
import chronos
import fresco/reactive/scope
import fresco/reactive/signal
import fresco/task/core

proc tick(): Future[void] {.async: (raises: [Exception]).} =
  ## Yield to the dispatcher one tick.
  await sleepAsync(0.milliseconds)

suite "task: spawn + Mount":

  test "spawn runs the coroutine; await returns when it finishes":
    proc body() {.async: (raises: [Exception]).} =
      proc work() {.async: (raises: [Exception]).} =
        await sleepAsync(5.milliseconds)
      let m = spawn work()
      check not m.finished
      await m.wait()
      check m.finished
    waitFor body()

  test "spawning inside a parent scope makes the task a structural child":
    proc body() {.async: (raises: [Exception]).} =
      let root = newScope()
      var m: Mount
      withScope(root):
        proc work() {.async: (raises: [Exception]).} =
          await sleepAsync(50.milliseconds)
        m = spawn work()
      check m.scope.parent == root
    waitFor body()

  test "cancel terminates an in-flight task and disposes its scope":
    proc body() {.async: (raises: [Exception]).} =
      var cleanedUp = false
      proc work() {.async: (raises: [Exception]).} =
        try:
          await sleepAsync(500.milliseconds)
        finally:
          discard       # any user-side cleanup
      let m = spawn work()
      withScope(m.scope):
        onCleanup proc() = cleanedUp = true
      await tick()
      m.cancel()
      await tick(); await tick()    # let the cancellation propagate
      check m.scope.disposed
      check cleanedUp
    waitFor body()

  test "task completion disposes its scope (cleanups fire after work)":
    proc body() {.async: (raises: [Exception]).} =
      var cleanedUp = false
      proc work() {.async: (raises: [Exception]).} =
        await sleepAsync(5.milliseconds)
      let m = spawn work()
      withScope(m.scope):
        onCleanup proc() = cleanedUp = true
      await m.wait()
      await tick()
      check m.scope.disposed
      check cleanedUp
    waitFor body()

  test "disposing the parent scope cancels the task":
    proc body() {.async: (raises: [Exception]).} =
      let parent = newScope()
      var m: Mount
      withScope(parent):
        proc work() {.async: (raises: [Exception]).} =
          await sleepAsync(500.milliseconds)
        m = spawn work()
      await tick()
      dispose(parent)
      await tick(); await tick()
      check m.future.finished
      check m.scope.disposed
    waitFor body()

  test "signals declared inside a task are owned by its scope":
    proc body() {.async: (raises: [Exception]).} =
      var observed: seq[int] = @[]
      proc work() {.async: (raises: [Exception]).} =
        let count = signal(0)
        createEffect proc() = observed.add count()
        count.set(1)
        count.set(2)
        await sleepAsync(5.milliseconds)
      let m = spawn work()
      await m.wait()
      check observed == @[0, 1, 2]
      # After completion, the scope is disposed; the effect no longer
      # observes anything (proven by the next test).
      check m.scope.disposed
    waitFor body()

  test "effects from a disposed task no longer run":
    proc body() {.async: (raises: [Exception]).} =
      var runs = 0
      let outer = signal(0)
      proc work() {.async: (raises: [Exception]).} =
        createEffect proc() =
          discard outer()
          inc runs
        await sleepAsync(5.milliseconds)
      let m = spawn work()
      await m.wait()
      let runsBefore = runs
      outer.set(99)
      await tick()
      check runs == runsBefore
    waitFor body()
