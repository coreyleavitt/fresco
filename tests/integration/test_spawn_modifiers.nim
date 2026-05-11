## spawnRetry and spawnCatch integration tests.

import std/unittest
import chronos
import fresco/task/core

proc tick(): Future[void] {.async: (raises: [CancelledError]).} =
  await sleepAsync(0.milliseconds)

suite "spawnRetry":

  test "retries until success":
    proc body() {.async: (raises: [Exception]).} =
      var attempts = 0
      proc flaky(): Future[void] {.async.} =
        inc attempts
        if attempts < 3:
          raise newException(ValueError, "not yet")
        await sleepAsync(1.milliseconds)
      let m = spawnRetry(5, flaky())
      await m.wait()
      check attempts == 3
    waitFor body()

  test "gives up after max retries and the Mount fails":
    proc body() {.async: (raises: [Exception]).} =
      var attempts = 0
      proc alwaysFails(): Future[void] {.async.} =
        inc attempts
        raise newException(ValueError, "boom")
      let m = spawnRetry(2, alwaysFails())   # 1 initial + 2 retries = 3 calls
      var caught = false
      try:
        await m.wait()
      except ValueError:
        caught = true
      check caught
      check attempts == 3
    waitFor body()

  test "cancellation stops further retries":
    proc body() {.async: (raises: [Exception]).} =
      var attempts = 0
      proc slowFail(): Future[void] {.async.} =
        inc attempts
        await sleepAsync(50.milliseconds)
        raise newException(ValueError, "boom")
      let m = spawnRetry(10, slowFail())
      await sleepAsync(70.milliseconds)
      m.cancel()
      await tick(); await tick()
      check attempts <= 3   # well below the 11 it would do without cancel
    waitFor body()

suite "spawnCatch":

  test "swallows a failure; Mount completes successfully":
    proc body() {.async: (raises: [Exception]).} =
      proc broken(): Future[void] {.async.} =
        raise newException(IOError, "boom")
      let m = spawnCatch(broken())
      await m.wait()
      check not m.future.failed
    waitFor body()

  test "doesn't swallow CancelledError":
    proc body() {.async: (raises: [Exception]).} =
      proc slow(): Future[void] {.async.} =
        await sleepAsync(500.milliseconds)
      let m = spawnCatch(slow())
      m.cancel()
      await tick(); await tick()
      check m.future.finished
    waitFor body()
