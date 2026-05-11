## sOneForAll + sRestForOne strategies.

import std/unittest
import chronos
import fresco/task/core
import fresco/task/supervisor

proc tick(): Future[void] {.async: (raises: [CancelledError]).} =
  await sleepAsync(0.milliseconds)

suite "supervisor strategies":

  test "sOneForAll: a single failure restarts every child":
    proc body() {.async: (raises: [Exception]).} =
      var startsA = 0
      var startsB = 0
      var startsC = 0
      proc childA(): Future[void] {.async.} =
        inc startsA
        await sleepAsync(2.milliseconds)
        if startsA == 1: raise newException(IOError, "boom")
      proc childB(): Future[void] {.async.} =
        inc startsB
        await sleepAsync(500.milliseconds)
      proc childC(): Future[void] {.async.} =
        inc startsC
        await sleepAsync(500.milliseconds)
      let sup = newSupervisor(strategy = sOneForAll,
                              maxRestarts = 10, within = 1.seconds)
      sup.addChild("a", lcTransient, childA)
      sup.addChild("b", lcTransient, childB)
      sup.addChild("c", lcTransient, childC)
      let m = spawn sup.run()
      await sleepAsync(40.milliseconds)
      m.cancel()
      # Each child started at least twice — once initial, once after
      # A's failure cascaded the restart.
      check startsA >= 2
      check startsB >= 2
      check startsC >= 2
    waitFor body()

  test "sRestForOne: only the failing child and later siblings restart":
    proc body() {.async: (raises: [Exception]).} =
      var startsA = 0
      var startsB = 0
      var startsC = 0
      proc childA(): Future[void] {.async.} =
        inc startsA
        await sleepAsync(500.milliseconds)
      proc childB(): Future[void] {.async.} =
        inc startsB
        await sleepAsync(2.milliseconds)
        if startsB == 1: raise newException(IOError, "boom")
      proc childC(): Future[void] {.async.} =
        inc startsC
        await sleepAsync(500.milliseconds)
      let sup = newSupervisor(strategy = sRestForOne,
                              maxRestarts = 10, within = 1.seconds)
      sup.addChild("a", lcTransient, childA)
      sup.addChild("b", lcTransient, childB)
      sup.addChild("c", lcTransient, childC)
      let m = spawn sup.run()
      await sleepAsync(40.milliseconds)
      m.cancel()
      # A (declared before B) should NOT have restarted. B and C should.
      check startsA == 1
      check startsB >= 2
      check startsC >= 2
    waitFor body()

  test "sOneForOne (default) does not cascade":
    proc body() {.async: (raises: [Exception]).} =
      var startsA = 0
      var startsB = 0
      proc childA(): Future[void] {.async.} =
        inc startsA
        await sleepAsync(2.milliseconds)
        if startsA == 1: raise newException(IOError, "boom")
      proc childB(): Future[void] {.async.} =
        inc startsB
        await sleepAsync(500.milliseconds)
      let sup = newSupervisor(maxRestarts = 10, within = 1.seconds)
      sup.addChild("a", lcTransient, childA)
      sup.addChild("b", lcTransient, childB)
      let m = spawn sup.run()
      await sleepAsync(40.milliseconds)
      m.cancel()
      check startsA >= 2
      check startsB == 1     # B untouched by A's failure
    waitFor body()
