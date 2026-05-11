## mountWhen integration tests.

{.experimental: "callOperator".}

import std/unittest
import chronos
import fresco/reactive/scope
import fresco/reactive/signal
import fresco/task/core
import fresco/task/mount

proc tick(): Future[void] {.async: (raises: [CancelledError]).} =
  await sleepAsync(0.milliseconds)

suite "mountWhen":

  test "mounts when condition becomes true; unmounts when false":
    proc body() {.async: (raises: [Exception]).} =
      var childActive = false
      proc child() {.async: (raises: [Exception]).} =
        childActive = true
        try:
          await sleepAsync(1000.milliseconds)
        finally:
          childActive = false
      let show = signal(false)
      let root = createRoot:
        mountWhen(show()):
          spawn child()
      await tick()
      check not childActive
      show.set(true)
      await tick(); await tick()
      check childActive
      show.set(false)
      await tick(); await tick()
      check not childActive
      dispose(root)
    waitFor body()

  test "remounts on second true after a false transition":
    proc body() {.async: (raises: [Exception]).} =
      var instantiations = 0
      proc child() {.async: (raises: [Exception]).} =
        inc instantiations
        try:
          await sleepAsync(1000.milliseconds)
        except CancelledError:
          raise
      let show = signal(false)
      let root = createRoot:
        mountWhen(show()):
          spawn child()
      show.set(true);  await tick(); await tick()
      show.set(false); await tick(); await tick()
      show.set(true);  await tick(); await tick()
      check instantiations == 2
      dispose(root)
    waitFor body()

  test "scope dispose cancels the active mount":
    proc body() {.async: (raises: [Exception]).} =
      var cleanedUp = false
      proc child() {.async: (raises: [Exception]).} =
        try:
          await sleepAsync(1000.milliseconds)
        except CancelledError:
          cleanedUp = true
          raise
      let show = signal(true)
      let root = createRoot:
        mountWhen(show()):
          spawn child()
      await tick(); await tick()
      dispose(root)
      await tick(); await tick()
      check cleanedUp
    waitFor body()

  test "mountWhen body that yields nil-equivalent never mounts":
    proc body() {.async: (raises: [Exception]).} =
      var ran = false
      proc child() {.async: (raises: [Exception]).} =
        ran = true
        await sleepAsync(5.milliseconds)
      let show = signal(false)   # always false
      let root = createRoot:
        mountWhen(show()):
          spawn child()
      await tick(); await tick()
      check not ran
      dispose(root)
    waitFor body()
