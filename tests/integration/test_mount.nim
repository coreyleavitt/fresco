## mountWhen integration tests.

{.experimental: "callOperator".}

import std/unittest
import chronos
import intonaco/reactive

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
      let show {.height: 0.} = signalC(false)
      let root = createRoot:
        mountWhen(show):
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
      let show {.height: 0.} = signalC(false)
      let root = createRoot:
        mountWhen(show):
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
      let show {.height: 0.} = signalC(true)
      let root = createRoot:
        mountWhen(show):
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
      let show {.height: 0.} = signalC(false)   # always false
      let root = createRoot:
        mountWhen(show):
          spawn child()
      await tick(); await tick()
      check not ran
      dispose(root)
    waitFor body()

  test "rapid toggle false→true→false→true still remounts each true edge":
    # Regression for review finding #13: cancel uses cancelSoon (async)
    # so the cancelled future may not be `finished` immediately. Verify
    # that a fast toggle sequence still produces one fresh mount per
    # rising edge.
    proc body() {.async: (raises: [Exception]).} =
      var instantiations = 0
      proc child() {.async.} =
        inc instantiations
        try:
          await sleepAsync(500.milliseconds)
        except CancelledError: raise
      let show {.height: 0.} = signalC(false)
      let root = createRoot:
        mountWhen(show):
          spawn child()
      # Toggle without yielding to dispatcher between flips.
      show := true; show := false
      show := true; show := false
      show := true; show := false
      await tick(); await tick(); await tick()
      check instantiations == 3
      dispose(root)
    waitFor body()

  test "mount(cond) alias has the same semantics as mountWhen":
    proc body() {.async: (raises: [Exception]).} =
      var active = false
      proc child() {.async: (raises: [Exception]).} =
        active = true
        try:
          await sleepAsync(500.milliseconds)
        finally:
          active = false
      let show {.height: 0.} = signalC(false)
      let root = createRoot:
        mount(show):
          spawn child()
      show := true
      await tick(); await tick()
      check active
      show := false
      await tick(); await tick()
      check not active
      dispose(root)
    waitFor body()
