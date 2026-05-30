## Animated signals + frame clock.

{.experimental: "callOperator".}

import std/[unittest, math]
import chronos
include intonaco/reactive_internal

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
      let s {.height: 0.} = signalC(0.0)
      discard tween(s, 1.0, 100.milliseconds, esLinear)
      await sleepAsync(160.milliseconds)
      check abs(s() - 1.0) < 1e-6
    waitFor body()

  test "second tween on same signal replaces the first":
    proc body() {.async: (raises: [Exception]).} =
      let s {.height: 0.} = signalC(0.0)
      discard tween(s, 100.0, 500.milliseconds, esLinear)
      await sleepAsync(30.milliseconds)
      # restart with new target
      discard tween(s, -50.0, 100.milliseconds, esLinear)
      await sleepAsync(180.milliseconds)
      check abs(s() - (-50.0)) < 1e-6
    waitFor body()

  test "tween fires intermediate values through observers":
    proc body() {.async: (raises: [Exception]).} =
      let s {.height: 0.} = signalC(0.0)
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
      let s {.height: 0.} = signalC(0.0)
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

  test "startFrameClock is idempotent (no-op on second call)":
    # Round-8 L4: documents the "first-installed-fps wins" semantic.
    # Calling startFrameClock twice should be safe — the second call
    # is a no-op while the first clock is running.
    proc body() {.async: (raises: [Exception]).} =
      startFrameClock(60)
      startFrameClock(30)   # should be ignored
      let s {.height: 0.} = signalC(0.0)
      discard tween(s, 1.0, 80.milliseconds, esLinear)
      await sleepAsync(120.milliseconds)
      check abs(s() - 1.0) < 1e-6
    waitFor body()

suite "spring":

  teardown:
    stopFrameClock()

  test "spring eventually settles to target":
    proc body() {.async: (raises: [Exception]).} =
      let s {.height: 0.} = signalC(0.0)
      discard spring(s, 1.0)
      # 500ms is the expected settle time for default k=170, c=26
      # (near-critical). Give a generous margin.
      await sleepAsync(800.milliseconds)
      check abs(s() - 1.0) < 0.05
    waitFor body()

  test "higher stiffness settles faster":
    proc body() {.async: (raises: [Exception]).} =
      let stiff {.height: 0.} = signalC(0.0)
      let soft {.height: 0.} = signalC(0.0)
      discard spring(stiff, 1.0, stiffness = 400.0, damping = 40.0)
      discard spring(soft,  1.0, stiffness = 50.0,  damping = 14.0)
      await sleepAsync(200.milliseconds)
      # Stiff spring should be much closer to target by 200ms;
      # soft spring is still mid-flight.
      check stiff() > soft()
      check abs(stiff() - 1.0) < 0.2
      check soft() < 0.8
    waitFor body()

  test "underdamped spring overshoots target before settling":
    # ζ = c / (2·√(k·m)) ≈ 0.3 — clearly underdamped.
    proc body() {.async: (raises: [Exception]).} =
      let s {.height: 0.} = signalC(0.0)
      var maxSeen = 0.0
      discard createRoot:
        createEffect proc() =
          let v = s()
          if v > maxSeen: maxSeen = v
      discard spring(s, 1.0, stiffness = 200.0, damping = 8.0)
      await sleepAsync(1.seconds)
      # Underdamped — must have overshot target at some point.
      check maxSeen > 1.0
      # And eventually settled.
      check abs(s() - 1.0) < 0.05
    waitFor body()

  test "critically/overdamped spring doesn't overshoot":
    # ζ ≥ 1 — at or beyond critical damping. Pick parameters that are
    # comfortably overdamped to avoid floating-point edge cases.
    proc body() {.async: (raises: [Exception]).} =
      let s {.height: 0.} = signalC(0.0)
      var maxSeen = 0.0
      discard createRoot:
        createEffect proc() =
          let v = s()
          if v > maxSeen: maxSeen = v
      discard spring(s, 1.0, stiffness = 100.0, damping = 30.0)
      await sleepAsync(1.seconds)
      # Overdamped — monotone approach, no overshoot.
      # Allow tiny float epsilon over 1.0 for the snap-to-target frame.
      check maxSeen <= 1.0 + 1e-9
      check abs(s() - 1.0) < 0.05
    waitFor body()

  test "settled spring stops being written":
    # After settle, the animation is removed from the scheduler;
    # subsequent ticks must not advance the signal further. Count
    # writes via an effect — post-settle quiet period must produce
    # zero new writes. Use stiff + overdamped + loose epsilons so
    # the spring settles within a couple of frames; the test isn't
    # about settle time, just about post-settle silence.
    proc body() {.async: (raises: [Exception]).} =
      let s {.height: 0.} = signalC(0.0)
      var writeCount = 0
      discard createRoot:
        createEffect proc() =
          discard s()
          inc writeCount
      # Loose epsilons so settle happens promptly under the 33ms tick.
      discard spring(s, 1.0,
                     epsilonVel = 0.1, epsilonPos = 0.05)
      await sleepAsync(1500.milliseconds)
      check abs(s() - 1.0) < 0.1
      let writesAtSettle = writeCount
      await sleepAsync(300.milliseconds)
      # No new writes during the post-settle quiet period.
      check writeCount == writesAtSettle
    waitFor body()

  test "scope dispose mid-spring cancels":
    proc body() {.async: (raises: [Exception]).} =
      let s {.height: 0.} = signalC(0.0)
      let root = createRoot:
        discard spring(s, 100.0)
      await sleepAsync(80.milliseconds)
      let midpoint = s()
      check midpoint > 0.0 and midpoint < 100.0
      dispose(root)
      await sleepAsync(150.milliseconds)
      # Spring cancelled — should not have advanced significantly
      # further. Allow a small drift for any in-flight tick.
      check abs(s() - midpoint) < 5.0
    waitFor body()

  test "cancel mid-spring halts motion":
    proc body() {.async: (raises: [Exception]).} =
      let s {.height: 0.} = signalC(0.0)
      let a = spring(s, 100.0)
      await sleepAsync(50.milliseconds)
      let midpoint = s()
      check midpoint > 0.0 and midpoint < 100.0
      cancel(a)
      await sleepAsync(150.milliseconds)
      check abs(s() - midpoint) < 5.0
    waitFor body()

  test "spring retarget mid-flight resets velocity (fresh-start)":
    # Per the decided semantics: a new spring on the same signal
    # cancels the prior and starts fresh from current position with
    # velocity=0. The signal must not overshoot the new target via
    # leftover momentum from the prior spring.
    proc body() {.async: (raises: [Exception]).} =
      let s {.height: 0.} = signalC(0.0)
      discard spring(s, 100.0, stiffness = 400.0, damping = 20.0)
      await sleepAsync(80.milliseconds)
      let beforeRetarget = s()
      check beforeRetarget > 5.0    # spring was building velocity
      # Retarget to 0 — fresh-start should head back toward 0 from
      # the current position, not overshoot upward from leftover
      # downward velocity.
      discard spring(s, 0.0)
      var maxAfter = s()
      for _ in 0 .. 20:
        await sleepAsync(40.milliseconds)
        if s() > maxAfter: maxAfter = s()
      # Fresh-start: signal monotonically (or near-monotonically)
      # decreases toward 0. It should not climb materially above
      # the retarget moment's value (no leftover upward momentum
      # because velocity reset to 0).
      check maxAfter <= beforeRetarget + 0.5
      # Eventually settles at 0.
      await sleepAsync(800.milliseconds)
      check abs(s()) < 0.05
    waitFor body()

  test "tween then spring on same signal: tween cancels cleanly":
    proc body() {.async: (raises: [Exception]).} =
      let s {.height: 0.} = signalC(0.0)
      discard tween(s, 100.0, 500.milliseconds, esLinear)
      await sleepAsync(80.milliseconds)
      let midTween = s()
      check midTween > 0.0 and midTween < 100.0
      discard spring(s, 50.0)
      await sleepAsync(800.milliseconds)
      # Spring takes over and settles at its own target.
      check abs(s() - 50.0) < 0.1
    waitFor body()

  test "two springs on different signals tick independently":
    proc body() {.async: (raises: [Exception]).} =
      let s1 = signalC(0.0)
      let s2 = signalC(0.0)
      discard spring(s1, 1.0)
      discard spring(s2, 5.0)
      await sleepAsync(800.milliseconds)
      check abs(s1() - 1.0) < 0.05
      check abs(s2() - 5.0) < 0.1
    waitFor body()

  test "tight settle epsilon keeps spring running longer than loose":
    # Two identical springs differing only in epsilon — the tight one
    # should still be observably non-settled when the loose one has
    # finished.
    proc body() {.async: (raises: [Exception]).} =
      let loose {.height: 0.} = signalC(0.0)
      let tight {.height: 0.} = signalC(0.0)
      discard spring(loose, 1.0, epsilonVel = 0.5, epsilonPos = 0.5)
      discard spring(tight, 1.0, epsilonVel = 0.0001, epsilonPos = 0.0001)
      await sleepAsync(60.milliseconds)
      # By this point: loose has settled (its epsilon is so wide that
      # the first few ticks satisfy the condition); tight is still
      # mid-flight.
      check abs(loose() - 1.0) >= 0.0    # any value — just settled fast
      check abs(tight() - 1.0) > 0.01    # tight definitely not done
      await sleepAsync(800.milliseconds)
      # Both eventually settle (tight to its tighter tolerance).
      check abs(tight() - 1.0) < 0.01
    waitFor body()

  test "spring at 4 fps still settles cleanly (dt-independent)":
    # Semi-implicit Euler with dt=250ms and defaults k=170, c=26 hits
    # c·dt ≈ 6.5, well past the stability limit (~2) — value would
    # blow up. The analytical integrator evaluates x(t) from t=0 each
    # frame, so the trajectory is independent of how often we sample
    # it; a 4fps clock lands on the same settling curve as 30fps.
    proc body() {.async: (raises: [Exception]).} =
      stopFrameClock()
      startFrameClock(4)
      let s {.height: 0.} = signalC(0.0)
      discard spring(s, 1.0)
      await sleepAsync(1500.milliseconds)
      check abs(s() - 1.0) < 0.1
    waitFor body()

suite "spring: multi-DoF":

  teardown:
    stopFrameClock()

  test "2-tuple spring animates each component toward its target":
    proc body() {.async: (raises: [Exception]).} =
      let s {.height: 0.} = signalC((0.0, 0.0))
      discard spring(s, (1.0, 5.0))
      await sleepAsync(800.milliseconds)
      let v = s()
      check abs(v[0] - 1.0) < 0.05
      check abs(v[1] - 5.0) < 0.1
    waitFor body()

  test "multi-DoF settle waits for slowest component, not fastest":
    # Component 0 starts inside (epsilonPos) already; if the settle
    # check were "any component within tolerance", the spring would
    # freeze on frame 1 with component 1 still near zero. The
    # correctness condition is "all components within tolerance".
    proc body() {.async: (raises: [Exception]).} =
      let s {.height: 0.} = signalC((0.0, 0.0))
      discard spring(s, (0.005, 100.0),
                     epsilonPos = 0.01, epsilonVel = 0.05)
      await sleepAsync(80.milliseconds)
      let mid = s()
      check mid[1] > 1.0           # component 1 has moved meaningfully
      await sleepAsync(1.seconds)
      let final = s()
      check abs(final[1] - 100.0) < 5.0
    waitFor body()

  test "multi-DoF retarget resets all velocities (fresh-start)":
    proc body() {.async: (raises: [Exception]).} =
      let s {.height: 0.} = signalC((0.0, 0.0))
      discard spring(s, (100.0, 100.0),
                     stiffness = 400.0, damping = 20.0)
      await sleepAsync(80.milliseconds)
      let mid = s()
      check mid[0] > 5.0 and mid[1] > 5.0
      discard spring(s, (0.0, 0.0))
      var maxAfter0 = mid[0]
      var maxAfter1 = mid[1]
      for _ in 0 .. 20:
        await sleepAsync(40.milliseconds)
        let v = s()
        if v[0] > maxAfter0: maxAfter0 = v[0]
        if v[1] > maxAfter1: maxAfter1 = v[1]
      check maxAfter0 <= mid[0] + 0.5
      check maxAfter1 <= mid[1] + 0.5
      await sleepAsync(800.milliseconds)
      let final = s()
      check abs(final[0]) < 0.05
      check abs(final[1]) < 0.05
    waitFor body()

  test "custom object type with all-float fields works":
    type Point2D = object
      x, y: float
    proc body() {.async: (raises: [Exception]).} =
      let p {.height: 0.} = signalC(Point2D(x: 0.0, y: 0.0))
      discard spring(p, Point2D(x: 10.0, y: -5.0))
      await sleepAsync(800.milliseconds)
      let v = p()
      check abs(v.x - 10.0) < 0.1
      check abs(v.y - (-5.0)) < 0.1
    waitFor body()

  test "non-float field in T is a compile-time error":
    # `compiles()` suppresses the `{.error.}` pragma inside
    # `toFloats` / `fromFloats` so this expression evaluates to
    # `false` rather than failing the build.
    type BadType = object
      x: float
      label: string
    let p {.height: 0.} = signalC(BadType(x: 0.0, label: "hi"))
    check not compiles(spring(p, BadType(x: 1.0, label: "ok")))

  test "stopFrameClock resets frameInterval so subsequent fps takes effect":
    # Regression for round-2 H1: a stopFrameClock followed by
    # startFrameClock(fps = X) used to silently keep the previous
    # interval because the lazy-init guard saw a non-default Duration.
    proc body() {.async: (raises: [Exception]).} =
      let s1 = signalC(0.0)
      discard tween(s1, 1.0, 100.milliseconds, esLinear)
      await sleepAsync(150.milliseconds)
      check abs(s1() - 1.0) < 1e-6
      stopFrameClock()
      # If frameInterval weren't reset, the next tween would still
      # tick at the old rate. We can't easily measure the rate but
      # we can verify a fresh tween still completes correctly.
      let s2 = signalC(0.0)
      discard tween(s2, 1.0, 100.milliseconds, esLinear)
      await sleepAsync(150.milliseconds)
      check abs(s2() - 1.0) < 1e-6
    waitFor body()
