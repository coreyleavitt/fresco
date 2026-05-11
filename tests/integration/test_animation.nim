## Animated signals + frame clock.

{.experimental: "callOperator".}

import std/[unittest, math]
import chronos
import fresco/reactive/scope
import fresco/reactive/signal
import fresco/reactive/animation

suite "easing curves":

  test "linear maps t to t":
    check applyEasing(0.0, esLinear) == 0.0
    check applyEasing(0.5, esLinear) == 0.5
    check applyEasing(1.0, esLinear) == 1.0

  test "easeIn/Out endpoints":
    for e in Easing:
      check applyEasing(0.0, e) == 0.0
      check applyEasing(1.0, e) == 1.0

  test "easeInQuad accelerates from 0":
    check applyEasing(0.5, esInQuad) == 0.25

  test "easeOutQuad decelerates to 1":
    let v = applyEasing(0.5, esOutQuad)
    check abs(v - 0.75) < 1e-9

suite "tween":

  teardown:
    stopFrameClock()

  test "tween progresses signal toward target and completes":
    proc body() {.async: (raises: [Exception]).} =
      let s = signal(0.0)
      discard tween(s, 1.0, 100.milliseconds, esLinear)
      await sleepAsync(160.milliseconds)
      check abs(s() - 1.0) < 1e-6
    waitFor body()

  test "second tween on same signal replaces the first":
    proc body() {.async: (raises: [Exception]).} =
      let s = signal(0.0)
      discard tween(s, 100.0, 500.milliseconds, esLinear)
      await sleepAsync(30.milliseconds)
      # restart with new target
      discard tween(s, -50.0, 100.milliseconds, esLinear)
      await sleepAsync(180.milliseconds)
      check abs(s() - (-50.0)) < 1e-6
    waitFor body()

  test "tween fires intermediate values through observers":
    proc body() {.async: (raises: [Exception]).} =
      let s = signal(0.0)
      var samples: seq[float] = @[]
      discard createRoot:
        createEffect proc() = samples.add s()
      discard tween(s, 10.0, 100.milliseconds, esLinear)
      await sleepAsync(160.milliseconds)
      # Should have collected several intermediate samples; last is target.
      check samples.len >= 3
      check abs(samples[^1] - 10.0) < 1e-6
      # Intermediate values lie in [0, 10].
      for v in samples:
        check v >= 0.0 and v <= 10.0
    waitFor body()

  test "scope dispose mid-tween cancels the animation":
    # Regression for round-2 H2: a tween used to keep writing to its
    # target signal until elapsed >= duration, even after the owning
    # scope had disposed. Now `tween` registers an onCleanup that
    # marks the animation cancelled.
    proc body() {.async: (raises: [Exception]).} =
      let s = signal(0.0)
      let root = createRoot:
        discard tween(s, 100.0, 500.milliseconds, esLinear)
      # Let a couple of frames tick so the tween starts moving.
      await sleepAsync(80.milliseconds)
      let midpoint = s()
      check midpoint > 0.0 and midpoint < 100.0
      dispose(root)
      await sleepAsync(80.milliseconds)
      let afterDispose = s()
      # Animation cancelled — value frozen at midpoint, no further updates.
      check abs(afterDispose - midpoint) < 1.0
    waitFor body()

  test "stopFrameClock resets frameInterval so subsequent fps takes effect":
    # Regression for round-2 H1: a stopFrameClock followed by
    # startFrameClock(fps = X) used to silently keep the previous
    # interval because the lazy-init guard saw a non-default Duration.
    proc body() {.async: (raises: [Exception]).} =
      let s1 = signal(0.0)
      discard tween(s1, 1.0, 100.milliseconds, esLinear)
      await sleepAsync(150.milliseconds)
      check abs(s1() - 1.0) < 1e-6
      stopFrameClock()
      # If frameInterval weren't reset, the next tween would still
      # tick at the old rate. We can't easily measure the rate but
      # we can verify a fresh tween still completes correctly.
      let s2 = signal(0.0)
      discard tween(s2, 1.0, 100.milliseconds, esLinear)
      await sleepAsync(150.milliseconds)
      check abs(s2() - 1.0) < 1e-6
    waitFor body()
