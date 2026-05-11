## Per-exception onError policies on supervisor children.

import std/unittest
import chronos
import fresco/task/core
import fresco/task/supervisor

suite "supervisor onError policies":

  test "policy returning eaRestart restarts (subject to rate window)":
    proc body() {.async: (raises: [Exception]).} =
      var attempts = 0
      proc child(): Future[void] {.async.} =
        inc attempts
        await sleepAsync(1.milliseconds)
        if attempts < 3:
          raise newException(IOError, "io")

      let sup = newSupervisor(maxRestarts = 10, within = 1.seconds)
      sup.addChild("c", lcTransient, child,
        onError = proc(e: ref Exception): ErrorAction = eaRestart)
      await sup.run()
      check attempts == 3
    waitFor body()

  test "policy returning eaTerminate stops without rate-limit escalation":
    proc body() {.async: (raises: [Exception]).} =
      var attempts = 0
      proc flaky(): Future[void] {.async.} =
        inc attempts
        await sleepAsync(1.milliseconds)
        raise newException(IOError, "io")

      let sup = newSupervisor(maxRestarts = 100, within = 1.seconds)
      sup.addChild("c", lcPermanent, flaky,
        onError = proc(e: ref Exception): ErrorAction = eaTerminate)
      # Should return cleanly (child removed) without escalating.
      await sup.run()
      check attempts == 1
    waitFor body()

  test "policy returning eaEscalate raises immediately, bypassing rate window":
    proc body() {.async: (raises: [Exception]).} =
      var attempts = 0
      proc flaky(): Future[void] {.async.} =
        inc attempts
        await sleepAsync(1.milliseconds)
        raise newException(IOError, "io")

      let sup = newSupervisor(maxRestarts = 100, within = 1.seconds)
      sup.addChild("c", lcPermanent, flaky,
        onError = proc(e: ref Exception): ErrorAction = eaEscalate)
      var caught = false
      try:
        await sup.run()
      except SupervisorEscalation as e:
        caught = true
        check e.childName == "c"
      check caught
      check attempts == 1
    waitFor body()

  test "policy can branch on exception type":
    proc body() {.async: (raises: [Exception]).} =
      var attempts = 0
      proc mixed(): Future[void] {.async.} =
        inc attempts
        await sleepAsync(1.milliseconds)
        if attempts == 1:
          raise newException(IOError, "retry me")
        if attempts == 2:
          raise newException(ValueError, "give up")

      let sup = newSupervisor(maxRestarts = 100, within = 1.seconds)
      sup.addChild("c", lcPermanent, mixed,
        onError = proc(e: ref Exception): ErrorAction =
          if e of IOError: eaRestart
          elif e of ValueError: eaTerminate
          else: eaEscalate)
      await sup.run()
      check attempts == 2     # IOError → restart, ValueError → terminate
    waitFor body()

  test "no policy: falls through to lifecycle default":
    proc body() {.async: (raises: [Exception]).} =
      var attempts = 0
      proc flaky(): Future[void] {.async.} =
        inc attempts
        await sleepAsync(1.milliseconds)
        raise newException(IOError, "io")

      let sup = newSupervisor(maxRestarts = 2, within = 1.seconds)
      # No onError. Permanent lifecycle restarts; rate window applies.
      sup.addChild("c", lcPermanent, flaky)
      var caught = false
      try:
        await sup.run()
      except SupervisorEscalation:
        caught = true
      check caught
      check attempts >= 3     # Restarts until rate window exceeded.
    waitFor body()
