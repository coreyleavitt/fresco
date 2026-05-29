## Supervisor integration tests — lifecycle types + restart windowing.

import std/unittest
import chronos
import intonaco/reactive

proc tick(): Future[void] {.async: (raises: [CancelledError]).} =
  await sleepAsync(0.milliseconds)

suite "supervisor: lifecycle behaviors":

  test "lcPermanent restarts after clean exit":
    proc body() {.async: (raises: [Exception]).} =
      var starts = 0
      proc child(): Future[void] {.async.} =
        inc starts
        await sleepAsync(2.milliseconds)
      let sup = newSupervisor(maxRestarts = 10, within = 1.seconds)
      sup.addChild("c", lcPermanent, child)
      let m = spawn sup.run()
      await sleepAsync(40.milliseconds)
      m.cancel()
      check starts >= 3
    waitFor body()

  test "lcTemporary never restarts; supervisor returns when done":
    proc body() {.async: (raises: [Exception]).} =
      var starts = 0
      proc child(): Future[void] {.async.} =
        inc starts
        await sleepAsync(2.milliseconds)
      let sup = newSupervisor()
      sup.addChild("c", lcTemporary, child)
      await sup.run()
      check starts == 1
    waitFor body()

  test "lcTransient restarts on failure, not on clean exit":
    proc body() {.async: (raises: [Exception]).} =
      var starts = 0
      proc successChild(): Future[void] {.async.} =
        inc starts
        await sleepAsync(2.milliseconds)
      let supA = newSupervisor()
      supA.addChild("c", lcTransient, successChild)
      await supA.run()
      check starts == 1

      starts = 0
      proc failingChild(): Future[void] {.async.} =
        inc starts
        await sleepAsync(2.milliseconds)
        if starts < 3:
          raise newException(ValueError, "boom")
        # After two failures it completes normally.
      let supB = newSupervisor(maxRestarts = 10, within = 1.seconds)
      supB.addChild("c", lcTransient, failingChild)
      await supB.run()
      check starts == 3
    waitFor body()

suite "supervisor: restart-rate window":

  test "exceeding maxRestarts within window escalates":
    proc body() {.async: (raises: [Exception]).} =
      var starts = 0
      proc flap(): Future[void] {.async.} =
        inc starts
        await sleepAsync(1.milliseconds)
        raise newException(ValueError, "always fails")
      let sup = newSupervisor(maxRestarts = 3, within = 1.seconds)
      sup.addChild("flap", lcPermanent, flap)
      var caught = false
      try:
        await sup.run()
      except SupervisorEscalation as e:
        caught = true
        check e.childName == "flap"
      check caught
      check starts >= 4
    waitFor body()

  test "restarts that age out of the window do not count":
    proc body() {.async: (raises: [Exception]).} =
      var starts = 0
      proc child(): Future[void] {.async.} =
        inc starts
        await sleepAsync(15.milliseconds)
      let sup = newSupervisor(maxRestarts = 2, within = 30.milliseconds)
      sup.addChild("c", lcPermanent, child)
      let m = spawn sup.run()
      # ~3 restarts in 60ms, but the window is 30ms so they age out;
      # supervisor should still be alive.
      await sleepAsync(80.milliseconds)
      check not m.future.finished
      m.cancel()
    waitFor body()

suite "supervisor: declarative block":

  test "supervisor: macro builds a Supervisor with config and children":
    proc body() {.async: (raises: [Exception]).} =
      var startsA = 0
      var startsB = 0
      proc childA(): Future[void] {.async.} =
        inc startsA
        await sleepAsync(2.milliseconds)
      proc childB(): Future[void] {.async.} =
        inc startsB
        await sleepAsync(2.milliseconds)

      supervisor mySup:
        maxRestarts = 10
        within = 1.seconds
        child("a", lcPermanent, childA)
        child("b", lcTemporary, childB)

      check mySup is Supervisor
      let m = spawn mySup.run()
      await sleepAsync(30.milliseconds)
      m.cancel()
      check startsA >= 2     # permanent → restarted
      check startsB == 1     # temporary → one shot
    waitFor body()

suite "supervisor: cancellation":

  test "cancelling the supervisor cancels all children":
    proc body() {.async: (raises: [Exception]).} =
      var alive = 0
      proc child(): Future[void] {.async.} =
        inc alive
        try:
          await sleepAsync(500.milliseconds)
        finally:
          dec alive
      let sup = newSupervisor()
      sup.addChild("a", lcPermanent, child)
      sup.addChild("b", lcPermanent, child)
      let m = spawn sup.run()
      await sleepAsync(10.milliseconds)
      check alive == 2
      m.cancel()
      await tick(); await tick(); await tick()
      check alive == 0
    waitFor body()
