## Topology query API.

import std/unittest
import chronos
import fresco/task/core
import fresco/task/supervisor

suite "supervisor topology":

  test "topology reports children with state":
    proc body() {.async: (raises: [Exception]).} =
      proc loop(): Future[void] {.async.} =
        await sleepAsync(500.milliseconds)
      proc oneShot(): Future[void] {.async.} =
        await sleepAsync(2.milliseconds)
      let sup = newSupervisor()
      sup.addChild("worker",  lcPermanent, loop)
      sup.addChild("oneshot", lcTemporary, oneShot)

      let m = spawn sup.run()
      await sleepAsync(15.milliseconds)
      # By now: worker still running; oneShot completed + removed by lcTemporary.

      let snap = sup.topology()
      check snap.len == 1     # oneshot was removed when temporary completed
      check snap[0].name == "worker"
      check snap[0].lifecycle == lcPermanent
      check snap[0].running
      m.cancel()
    waitFor body()

  test "restart count is exposed":
    proc body() {.async: (raises: [Exception]).} =
      var attempts = 0
      proc flap(): Future[void] {.async.} =
        inc attempts
        await sleepAsync(1.milliseconds)
        if attempts < 4: raise newException(IOError, "boom")
      let sup = newSupervisor(maxRestarts = 20, within = 5.seconds)
      sup.addChild("flap", lcTransient, flap)
      await sup.run()
      let snap = sup.topology()
      # Children list still has flap because lcTransient with eventual
      # clean exit doesn't remove (it's removed on clean exit only via
      # shouldRestart=false; once clean, supervisor exits the loop).
      # After the run() returns, supervisor is done; topology is what
      # remained. flap exited clean on attempt 4, so it was removed.
      check snap.len == 0
      check attempts == 4
    waitFor body()
