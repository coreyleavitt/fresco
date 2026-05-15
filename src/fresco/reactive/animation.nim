## Animated signals — piecewise FRP behaviors with a frame clock.
##
##   tween(scroll, target = 100.0, 200.milliseconds, esOutCubic)
##   spring(scroll, target = 100.0)
##   spring(pos2d, Point2D(x: 10.0, y: 5.0))
##
## A `tween` creates an Animation: a closure that, for each frame
## while the tween is running, writes an interpolated value into the
## target signal. The module-global frame clock wakes at ~30 fps and
## advances every in-flight animation. When elapsed >= duration the
## animation completes (signal fixed at target) and is removed.
##
## `spring` integrates the damped harmonic oscillator analytically:
## each frame evaluates the closed-form x(t) from t=0 (the spring's
## start moment), so the trajectory is independent of frame rate or
## dt jitter — a stiff spring viewed at 10 fps reaches the same
## intermediate point at the same wall-clock time as the same spring
## viewed at 144 fps. Spring is generic over T: T = float | tuple |
## object whose fields are all `float`. Each float field animates as
## an independent 1-D spring sharing the same (k, c) constants; the
## animation settles when ALL components are within (epsilonVel,
## epsilonPos).

import std/math
import chronos
import ./signal
import ./scope

type
  Easing* = enum
    esLinear
    esInQuad
    esOutQuad
    esInOutQuad
    esInCubic
    esOutCubic
    esInOutCubic

  AnimKind* = enum
    akTween
    akSpring

  SpringWriteback = proc(values: seq[float], terminal: bool)
                    {.closure, gcsafe, raises: [].}
    ## Writes a per-component position vector back to the typed
    ## Signal[T] that the spring is bound to. `terminal = true` on
    ## the settle frame routes through `set` (journaled) under the
    ## origin scope; intermediate frames use `setUntracked`. The
    ## closure captures both the Signal[T] and the originScope so
    ## the Animation record stays untyped.

  Animation* = ref object
    cancelled: bool
    originScope: Scope
      ## Scope current when the animation was created. Used by the
      ## tween's terminal write and captured into the spring's
      ## writeback closure so the journal entry attributes to the
      ## task that originated the animation, not to whichever
      ## coroutine the dispatcher left in `currentScope` when the
      ## frame clock ticked.
    signalId: pointer
      ## Pointer-identity of the bound Signal, used for cross-kind
      ## collision detection (a new spring or tween on the same
      ## signal cancels any prior animation on that signal). Erased
      ## via `cast[pointer]` so a single `Animation` type can carry
      ## bindings of differently-typed signals.
    case kind: AnimKind
    of akTween:
      target: Signal[float]
      startVal, endVal: float
      startMono: Moment
      duration: Duration
      easing: Easing
    of akSpring:
      springU0, springV0: seq[float]
        ## Per-component initial displacement (x0 - target) and
        ## initial velocity. Velocity is currently always zero on
        ## construction (fresh-start retarget); the field exists for
        ## a future `rtPreserve` opt-in.
      springTargets: seq[float]
        ## Per-component rest positions.
      springStart: Moment
        ## Wall-time t=0 for the analytical evaluation. Every frame
        ## computes (now - springStart) and evaluates x(t) from
        ## scratch — no incremental state, no dt clamp, no jitter.
      stiffness, damping: float
        ## Spring constants shared across all components. Mass is
        ## fixed at 1.0. Damping ratio ζ = damping / (2·√stiffness);
        ## defaults 170/26 give ζ≈0.999 (near-critical) and a
        ## ~500ms settle for a unit step.
      epsilonVel, epsilonPos: float
        ## Settle thresholds: spring completes when, for every
        ## component i, |velocity_i| < epsilonVel AND
        ## |position_i - target_i| < epsilonPos.
      springWriteback: SpringWriteback

const DefaultFPS* = 30

var frameAnimations {.threadvar.}: seq[Animation]
var frameClockTask {.threadvar.}: Future[void]
var frameInterval {.threadvar.}: Duration
  ## All three are thread-locals tied to the chronos dispatcher that
  ## first called `startFrameClock` (typically via `tween`/`spring`).
  ## Single-dispatcher apps (the fresco default) are unaffected.
  ## Cross-thread animation would require a shared list + a per-thread
  ## clock — not yet implemented.

proc cancel*(a: Animation) =
  ## Stop the animation. The next frame-clock tick discovers the
  ## `cancelled` flag and removes the entry from the scheduler.
  ## Idempotent.
  if a != nil: a.cancelled = true

proc applyEasing*(t: float, easing: Easing): float =
  let t = clamp(t, 0.0, 1.0)
  case easing
  of esLinear:      t
  of esInQuad:      t * t
  of esOutQuad:     1.0 - (1.0 - t) * (1.0 - t)
  of esInOutQuad:
    if t < 0.5: 2.0 * t * t
    else: 1.0 - pow(-2.0 * t + 2.0, 2) / 2.0
  of esInCubic:     t * t * t
  of esOutCubic:    1.0 - pow(1.0 - t, 3)
  of esInOutCubic:
    if t < 0.5: 4.0 * t * t * t
    else: 1.0 - pow(-2.0 * t + 2.0, 3) / 2.0

# --- Analytical spring ----------------------------------------------------

proc evalDampedOscillator(u0, v0, k, c, t: float):
                          tuple[u, du: float] =
  ## Closed-form solution to ü + c·u̇ + k·u = 0 with m=1, evaluated
  ## at time `t` for initial conditions (u0, v0). Returns the
  ## displacement-from-rest `u` and its derivative `du`. Three cases
  ## by the sign of the discriminant c² - 4k:
  ##   underdamped (disc < 0): oscillatory, exponentially decaying
  ##   critical    (disc = 0): repeated real root, no overshoot
  ##   overdamped  (disc > 0): sum of two decaying exponentials
  ## The critical case is detected by |disc| < ε to avoid numerical
  ## blow-up of the under/overdamped formulas as ω_d or r1-r2 → 0.
  let disc = c*c - 4.0*k
  if abs(disc) < 1e-9:
    let r = -c / 2.0
    let A = u0
    let B = v0 - r * u0
    let e = exp(r * t)
    let body = A + B*t
    result.u  = body * e
    result.du = (B + r*body) * e
  elif disc < 0.0:
    let zwn = c / 2.0
    let wd  = sqrt(-disc) / 2.0
    let A = u0
    let B = (v0 + zwn * u0) / wd
    let e   = exp(-zwn * t)
    let cwt = cos(wd * t)
    let swt = sin(wd * t)
    result.u  = e * (A*cwt + B*swt)
    result.du = e * ((-zwn*A + wd*B)*cwt + (-zwn*B - wd*A)*swt)
  else:
    let sq = sqrt(disc)
    let r1 = (-c + sq) / 2.0
    let r2 = (-c - sq) / 2.0
    let A = (v0 - r2*u0) / (r1 - r2)
    let B = u0 - A
    let e1 = exp(r1*t)
    let e2 = exp(r2*t)
    result.u  = A*e1 + B*e2
    result.du = r1*A*e1 + r2*B*e2

# --- Per-T pack/unpack ----------------------------------------------------

proc toFloats*[T](x: T): seq[float] =
  ## Flatten a spring value type into a seq of its float components.
  ## T must be `float`, or a tuple/object whose fields are all
  ## `float`. Order is field-declaration order (stable for both
  ## tuples and objects).
  when T is float:
    @[x]
  elif T is tuple or T is object:
    for _, val in fieldPairs(x):
      when val is float:
        result.add val
      else:
        {.error: "spring T must be float or a tuple/object of float fields".}
  else:
    {.error: "spring T must be float or a tuple/object of float fields".}

proc fromFloats*[T](xs: seq[float]): T =
  when T is float:
    xs[0]
  elif T is tuple or T is object:
    var idx = 0
    for _, val in fieldPairs(result):
      when val is float:
        val = xs[idx]
        inc idx
      else:
        {.error: "spring T must be float or a tuple/object of float fields".}
  else:
    {.error: "spring T must be float or a tuple/object of float fields".}

# --- Frame stepping -------------------------------------------------------

proc settledOriginSet(a: Animation, value: float) =
  if a.originScope != nil:
    withScope(a.originScope):
      a.target.set(value)
  else:
    a.target.set(value)

proc step(a: Animation, now: Moment): bool =
  ## Advance one frame. Returns true when the animation completes.
  ##
  ## Intermediate frames use `setUntracked` (no journal entry) — they
  ## are interpolation noise that would bloat the log without semantic
  ## value. The terminal frame writes the settled value through `set`
  ## under the origin scope so the journal attributes correctly.
  ##
  ## **Disposed-origin invariant:** `tween`/`spring` register an
  ## `onCleanup` against the origin scope that sets `a.cancelled = true`.
  ## If `originScope` is disposed before the animation completes, that
  ## cleanup fires first, the next clock tick's `if a.cancelled` guard
  ## returns true, and the terminal write never runs against a disposed
  ## scope.
  if a.cancelled: return true
  case a.kind
  of akTween:
    let elapsed = now - a.startMono
    if elapsed >= a.duration:
      settledOriginSet(a, a.endVal)
      return true
    let t = elapsed.nanoseconds.float / a.duration.nanoseconds.float
    let eased = applyEasing(t, a.easing)
    let v = a.startVal + (a.endVal - a.startVal) * eased
    a.target.setUntracked(v)
    return false
  of akSpring:
    let t = (now - a.springStart).nanoseconds.float / 1_000_000_000.0
    let n = a.springTargets.len
    var values = newSeq[float](n)
    var settled = true
    for i in 0 ..< n:
      let (u, du) = evalDampedOscillator(
        a.springU0[i], a.springV0[i], a.stiffness, a.damping, t)
      values[i] = a.springTargets[i] + u
      if abs(du) >= a.epsilonVel or abs(u) >= a.epsilonPos:
        settled = false
    if settled:
      a.springWriteback(a.springTargets, terminal = true)
      return true
    a.springWriteback(values, terminal = false)
    return false

proc clockLoop() {.async.} =
  while true:
    let now = Moment.now()
    var i = 0
    while i < frameAnimations.len:
      if frameAnimations[i].step(now):
        frameAnimations.del i
      else:
        inc i
    await sleepAsync(frameInterval)

proc startFrameClock*(fps: int = DefaultFPS) =
  ## Idempotent. Starts the module-global frame clock if it isn't
  ## already running. Most callers don't need to call this directly —
  ## `tween` / `spring` trigger it lazily.
  ##
  ## **If the clock is already running, `fps` is ignored.** To change
  ## the rate of a running clock, call `stopFrameClock()` first.
  if frameClockTask != nil and not frameClockTask.finished: return
  if frameInterval == default(Duration):
    frameInterval = max(1, 1000 div fps).milliseconds
  frameClockTask = clockLoop()

proc stopFrameClock*() =
  ## Cancel the frame clock. Animations in flight stop advancing
  ## immediately. Resets `frameInterval` so a subsequent
  ## `startFrameClock(fps = X)` actually picks up the new rate.
  if frameClockTask != nil and not frameClockTask.finished:
    frameClockTask.cancelSoon()
  frameClockTask = nil
  frameAnimations.setLen(0)
  frameInterval = default(Duration)

# --- Public API: tween + spring ------------------------------------------

proc tween*(s: Signal[float], target: float,
            duration: Duration, easing = esLinear): Animation
            {.discardable.} =
  ## Animate `s` from its current value to `target` over `duration`.
  ## If another animation (tween or spring) is already in flight
  ## against `s`, it is cancelled and replaced (last-write-wins).
  ##
  ## **Scope-less callers**: if called outside any scope, `originScope`
  ## is nil and `onCleanup` is a no-op — the animation has no
  ## automatic cancellation. Wrap in `createRoot:` or a `spawn`'d task
  ## for cancel-on-dispose semantics.
  let sid = cast[pointer](s)
  for a in frameAnimations:
    if a.signalId == sid: a.cancelled = true
  result = Animation(
    kind: akTween,
    signalId: sid,
    originScope: currentScope,
    target: s,
    startVal: s.peek(),
    endVal: target,
    startMono: Moment.now(),
    duration: duration,
    easing: easing)
  frameAnimations.add result
  let captured = result
  onCleanup proc() = captured.cancelled = true
  startFrameClock()

proc spring*[T](s: Signal[T], target: T,
                stiffness = 170.0, damping = 26.0,
                epsilonVel = 0.01, epsilonPos = 0.01): Animation
                {.discardable.} =
  ## Physics-based animation: a damped harmonic oscillator per float
  ## component pulls `s` toward `target`. Defaults give ~500ms settle
  ## for a unit step (near-critical damping, no overshoot).
  ##
  ## T may be `float` or any tuple/object whose fields are all
  ## `float`. Each float component animates as an independent 1-D
  ## spring sharing the same (stiffness, damping); the animation
  ## settles when **every** component is within (epsilonVel,
  ## epsilonPos). A non-conforming T is a compile-time error from
  ## `toFloats` / `fromFloats`.
  ##
  ## **Closed-form integration:** each frame evaluates the analytical
  ## damped-oscillator solution at t = (now - start), independent of
  ## prior frames. The trajectory is frame-rate-independent and
  ## immune to dispatcher jitter — a 200ms-deep frame and a 1ms frame
  ## land on the same point in the same trajectory.
  ##
  ## **Retarget semantics:** if any animation is in flight against
  ## `s`, it is cancelled. The new spring starts from `s`'s current
  ## value with velocity = 0 in every component (fresh-start). A
  ## future `rtPreserve` opt-in would seed `springV0` from the
  ## evaluated derivative of the cancelled spring at retarget time;
  ## fresco's TUI use cases are state-transition-driven, not
  ## gesture-driven, so we ship without it.
  let sid = cast[pointer](s)
  for a in frameAnimations:
    if a.signalId == sid: a.cancelled = true
  let initVals = toFloats(s.peek())
  let targetVals = toFloats(target)
  let n = initVals.len
  var u0 = newSeq[float](n)
  let v0 = newSeq[float](n)  # zero-initialized — fresh-start
  for i in 0 ..< n:
    u0[i] = initVals[i] - targetVals[i]
  let originCap = currentScope
  let writeback: SpringWriteback =
    proc(values: seq[float], terminal: bool) {.closure, gcsafe, raises: [].} =
      let packed = fromFloats[T](values)
      if terminal:
        if originCap != nil:
          withScope(originCap):
            s.set(packed)
        else:
          s.set(packed)
      else:
        s.setUntracked(packed)
  result = Animation(
    kind: akSpring,
    signalId: sid,
    originScope: originCap,
    springU0: u0,
    springV0: v0,
    springTargets: targetVals,
    springStart: Moment.now(),
    stiffness: stiffness,
    damping: damping,
    epsilonVel: epsilonVel,
    epsilonPos: epsilonPos,
    springWriteback: writeback)
  frameAnimations.add result
  let captured = result
  onCleanup proc() = captured.cancelled = true
  startFrameClock()
