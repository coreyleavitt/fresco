## sOneForAll + sRestForOne strategies.

import std/[unittest, strutils]
import chronos
import fresco/task/core
import fresco/task/supervisor
import fresco/journal/events
import fresco/journal/log

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

  test "sRestForOne preserves declaration order after a temporary child terminates":
    # Regression: previously `s.children.del idx` was an unordered
    # swap-delete which silently reordered children. After any
    # temporary/clean exit, restForOne cascades operated on the
    # wrong "later siblings" set.
    proc body() {.async: (raises: [Exception]).} =
      var startsA = 0
      var startsB = 0   # this one terminates cleanly mid-run
      var startsC = 0
      proc childA(): Future[void] {.async.} =
        inc startsA
        await sleepAsync(500.milliseconds)
      proc childB(): Future[void] {.async.} =
        inc startsB
        await sleepAsync(5.milliseconds)
      proc childC(): Future[void] {.async.} =
        inc startsC
        await sleepAsync(40.milliseconds)
        if startsC == 1: raise newException(IOError, "boom")
      let sup = newSupervisor(strategy = sRestForOne,
                              maxRestarts = 10, within = 1.seconds)
      sup.addChild("a", lcTransient, childA)
      sup.addChild("b", lcTemporary, childB)   # exits cleanly → removed
      sup.addChild("c", lcTransient, childC)   # later fails
      let m = spawn sup.run()
      await sleepAsync(70.milliseconds)
      m.cancel()
      # After b's terminate, the children seq should still be [a, c]
      # in declaration order. When c fails, restForOne cascades from
      # c onward — A must not be restarted.
      check startsA == 1
      check startsC >= 2
    waitFor body()

  test "sOneForAll: cascade rate-limits every restarting child":
    # Regression for round-2 C3: previously only the originally-failing
    # child had its restartTimes bumped per cascade, so an all-children-
    # fail-on-init loop would bypass maxRestarts entirely. With the fix,
    # each cascade is a restart event for every cascaded child; the
    # supervisor escalates once any has exceeded its window.
    proc body() {.async: (raises: [Exception]).} =
      var startsA = 0
      var startsB = 0
      proc childA(): Future[void] {.async.} =
        inc startsA
        await sleepAsync(1.milliseconds)
        raise newException(IOError, "boom-a")
      proc childB(): Future[void] {.async.} =
        inc startsB
        await sleepAsync(1.milliseconds)
        raise newException(IOError, "boom-b")
      let sup = newSupervisor(strategy = sOneForAll,
                              maxRestarts = 3, within = 1.seconds)
      sup.addChild("a", lcPermanent, childA)
      sup.addChild("b", lcPermanent, childB)
      var escalated = false
      try:
        await sup.run()
      except SupervisorEscalation:
        escalated = true
      check escalated
      # Each child should have started no more than maxRestarts+1 times
      # (initial + maxRestarts restarts before the window check fires).
      # Without the fix, B alone could be restarted indefinitely while
      # only A's counter was tracked.
      check startsA <= 5
      check startsB <= 5
    waitFor body()

  test "cascade does not journal cancelled siblings as failures":
    # Regression for round-3 C4: the L3 fix that journaled
    # CatchableError from cascaded await calls accidentally swallowed
    # the cancellation case. Every sOneForAll cascade emitted N-1
    # spurious "concurrent failure" entries.
    proc body() {.async: (raises: [Exception]).} =
      discard useJournal()
      proc childA(): Future[void] {.async.} =
        await sleepAsync(2.milliseconds)
        raise newException(IOError, "boom")
      proc childB(): Future[void] {.async.} =
        await sleepAsync(500.milliseconds)
      proc childC(): Future[void] {.async.} =
        await sleepAsync(500.milliseconds)
      let sup = newSupervisor(strategy = sOneForAll,
                              maxRestarts = 5, within = 1.seconds)
      sup.addChild("a", lcTransient, childA)
      sup.addChild("b", lcTransient, childB)
      sup.addChild("c", lcTransient, childC)
      let m = spawn sup.run()
      await sleepAsync(30.milliseconds)
      m.cancel()
      # No "concurrent failure" entries for b or c — they were
      # deliberately cancelled, not concurrently failed.
      var bogusEntries = 0
      for ev in globalJournal.byKind(ekSupervisorEscalate):
        if ev.escalateReason.contains("concurrent failure"):
          inc bogusEntries
      check bogusEntries == 0
    waitFor body()

  test "onError eaRestart overrides lcTemporary lifecycle":
    # Regression for round-3 H1: previously eaRestart from onError
    # was silently dropped for lcTemporary children because
    # shouldRestart(lcTemporary, _) returned false, terminating the
    # child despite the policy saying restart.
    proc body() {.async: (raises: [Exception]).} =
      var starts = 0
      proc child(): Future[void] {.async.} =
        inc starts
        await sleepAsync(2.milliseconds)
        if starts < 3: raise newException(IOError, "boom")
      let sup = newSupervisor(maxRestarts = 10, within = 1.seconds)
      proc policy(e: ref Exception): ErrorAction {.gcsafe, raises: [].} =
        eaRestart  # always restart, regardless of lifecycle
      sup.addChild("c", lcTemporary, child, onError = policy)
      let m = spawn sup.run()
      await sleepAsync(40.milliseconds)
      m.cancel()
      check starts >= 3   # restarted past the first failure
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
