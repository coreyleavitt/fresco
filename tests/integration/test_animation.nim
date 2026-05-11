## Animated signals + frame clock.

{.experimental: "callOperator".}

import std/[unittest, math]
import chronos
import fresco/reactive/scope
import fresco/reactive/signal
import fresco/reactive/animation

suite "easing curves":

  test "linear maps t to t":
    check applyEasing(0.0, eLinear) == 0.0
    check applyEasing(0.5, eLinear) == 0.5
    check applyEasing(1.0, eLinear) == 1.0

  test "easeIn/Out endpoints":
    for e in Easing:
      check applyEasing(0.0, e) == 0.0
      check applyEasing(1.0, e) == 1.0

  test "easeInQuad accelerates from 0":
    check applyEasing(0.5, eEaseInQuad) == 0.25

  test "easeOutQuad decelerates to 1":
    let v = applyEasing(0.5, eEaseOutQuad)
    check abs(v - 0.75) < 1e-9

suite "tween":

  teardown:
    stopFrameClock()

  test "tween progresses signal toward target and completes":
    proc body() {.async: (raises: [Exception]).} =
      let s = signal(0.0)
      discard tween(s, 1.0, 100.milliseconds, eLinear)
      await sleepAsync(160.milliseconds)
      check abs(s() - 1.0) < 1e-6
    waitFor body()

  test "second tween on same signal replaces the first":
    proc body() {.async: (raises: [Exception]).} =
      let s = signal(0.0)
      discard tween(s, 100.0, 500.milliseconds, eLinear)
      await sleepAsync(30.milliseconds)
      # restart with new target
      discard tween(s, -50.0, 100.milliseconds, eLinear)
      await sleepAsync(180.milliseconds)
      check abs(s() - (-50.0)) < 1e-6
    waitFor body()

  test "tween fires intermediate values through observers":
    proc body() {.async: (raises: [Exception]).} =
      let s = signal(0.0)
      var samples: seq[float] = @[]
      discard createRoot:
        createEffect proc() = samples.add s()
      discard tween(s, 10.0, 100.milliseconds, eLinear)
      await sleepAsync(160.milliseconds)
      # Should have collected several intermediate samples; last is target.
      check samples.len >= 3
      check abs(samples[^1] - 10.0) < 1e-6
      # Intermediate values lie in [0, 10].
      for v in samples:
        check v >= 0.0 and v <= 10.0
    waitFor body()
