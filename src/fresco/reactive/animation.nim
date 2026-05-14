## Animated signals — piecewise FRP behaviors with a frame clock.
##
##   tween(scroll, target = 100.0, 200.milliseconds, esOutCubic)
##
## A `tween` creates an Animation: a closure that, for each frame
## while the tween is running, writes an interpolated value into the
## target signal. The module-global frame clock wakes at ~30 fps and
## advances every in-flight animation. When elapsed >= duration the
## animation completes (signal fixed at target) and is removed.
##
## v2.3 scope: `Signal[float]` only. Int/color/string interpolation is
## a follow-up — float covers scroll positions, progress bars, fade
## opacity, spring physics, etc. (the visible UX wins).

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

  Animation* = ref object
    target: Signal[float]
    cancelled: bool
    originScope: Scope
      ## Scope current when the animation was created. Restored around
      ## the terminal frame's `set` so the journal entry attributes to
      ## the task that originated the animation, not to whichever
      ## coroutine the dispatcher last left in `currentScope` when the
      ## frame clock ticked.
    case kind: AnimKind
    of akTween:
      startVal, endVal: float
      startMono: Moment
      duration: Duration
      easing: Easing
    of akSpring:
      springTarget: float
        ## The rest position the spring is pulling toward.
      position, velocity: float
        ## Current physical state. `position` is mirrored into the
        ## bound signal each frame (via setUntracked); `velocity` is
        ## internal and not exposed.
      stiffness, damping: float
        ## Spring constants. Mass is fixed at 1.0 by convention; tune
        ## stiffness/damping for feel. Damping ratio
        ## ζ = damping / (2·√(stiffness·mass)); ζ=1 is critically
        ## damped (no overshoot, fastest settle). Defaults 170/26
        ## give ζ≈0.999 (near-critical) and a ~500ms settle for a
        ## unit step.
      epsilonVel, epsilonPos: float
        ## Settle thresholds: spring completes when |velocity| <
        ## epsilonVel AND |position - springTarget| < epsilonPos.
      lastTickMono: Moment
        ## Used to compute real dt per step. Real dt (clamped to
        ## 100ms) is more accurate than the nominal frameInterval
        ## when the dispatcher is busy and frame ticks drift.

const DefaultFPS* = 30

var frameAnimations {.threadvar.}: seq[Animation]
  ## Internal scheduler list. Not exported — direct mutation would
  ## corrupt the clock loop's iterator. `tween` / `stopFrameClock`
  ## are the public API.
var frameClockTask {.threadvar.}: Future[void]
var frameInterval {.threadvar.}: Duration
  ## All three are thread-locals tied to the chronos dispatcher that
  ## first called `startFrameClock` (typically via `tween`). A `tween`
  ## issued from a different thread joins a list no clock is ticking,
  ## so its animation never advances. Single-dispatcher apps (the
  ## fresco default) are unaffected. Cross-thread animation would
  ## require a shared list + a per-thread clock — not yet implemented.

proc cancel*(a: Animation) =
  ## Stop the animation. The next frame-clock tick discovers the
  ## `cancelled` flag and removes the entry from the scheduler.
  ## Idempotent — calling twice is a no-op.
  ##
  ## Use this for scope-less callers (`tween` invoked outside any
  ## scope) that need to cancel explicitly. Scope-bound tweens get
  ## auto-cancel via the `onCleanup` registered at tween time.
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

proc settledOriginSet(a: Animation, value: float) =
  ## Terminal-frame write: re-enter the origin scope so the journal
  ## entry attributes to the originating task, not to whichever
  ## coroutine left `currentScope` set on the frame tick.
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
  ## value. The terminal frame routes through `settledOriginSet` so
  ## the settled value journals under the origin task's scope.
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
    # Real dt clamped to 100ms — protects against pathological velocity
    # spikes if the dispatcher hung for a long time between ticks.
    var dtNs = (now - a.lastTickMono).nanoseconds
    a.lastTickMono = now
    const MaxDtNs = 100_000_000  # 100ms
    if dtNs > MaxDtNs: dtNs = MaxDtNs
    if dtNs <= 0: return false   # zero/negative dt — no-op
    let dt = dtNs.float / 1_000_000_000.0
    # Semi-implicit Euler: update velocity first, then position with
    # the NEW velocity. Stable across the UI-relevant (k, c) range at
    # 30 FPS — explicit Euler overshoots at high stiffness.
    let force = -a.stiffness * (a.position - a.springTarget) -
                 a.damping * a.velocity
    a.velocity += force * dt
    a.position += a.velocity * dt
    # Settle: both velocity AND position within tolerance.
    if abs(a.velocity) < a.epsilonVel and
       abs(a.position - a.springTarget) < a.epsilonPos:
      a.position = a.springTarget    # snap to exact rest
      settledOriginSet(a, a.springTarget)
      return true
    a.target.setUntracked(a.position)
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
  ## `tween` triggers it lazily.
  ##
  ## **If the clock is already running, `fps` is ignored.** To change
  ## the rate of a running clock, call `stopFrameClock()` first (which
  ## resets `frameInterval`) and then `startFrameClock(newFps)`.
  if frameClockTask != nil and not frameClockTask.finished: return
  if frameInterval == default(Duration):
    frameInterval = max(1, 1000 div fps).milliseconds
  frameClockTask = clockLoop()

proc stopFrameClock*() =
  ## Cancel the frame clock. Animations in flight stop advancing
  ## immediately. Useful in tests to keep teardown deterministic.
  ##
  ## Resets `frameInterval` so a subsequent `startFrameClock(fps = X)`
  ## actually picks up the new rate — without this, the lazy-init
  ## guard in startFrameClock would see a non-default Duration and
  ## silently keep the previous interval.
  if frameClockTask != nil and not frameClockTask.finished:
    frameClockTask.cancelSoon()
  frameClockTask = nil
  frameAnimations.setLen(0)
  frameInterval = default(Duration)

proc tween*(s: Signal[float], target: float,
            duration: Duration, easing = esLinear): Animation
            {.discardable.} =
  ## Animate `s` from its current value to `target` over `duration`.
  ## If another tween is already in flight against `s`, it's cancelled
  ## and replaced with this one (last-write-wins).
  ##
  ## Cancelled animations stay in `frameAnimations` until the next
  ## frame-clock tick discovers their `cancelled = true` flag and
  ## removes them. Rapid back-to-back `tween` calls on the same
  ## signal within one dispatcher iteration can therefore accumulate
  ## entries in the list — bounded by frame interval (~33ms at 30fps)
  ## and self-corrects on the next tick.
  ##
  ## **Scope-less callers**: if `tween` is called outside any scope
  ## (`currentScope == nil`), `originScope` is captured as nil and
  ## `onCleanup` is a no-op. The animation has no automatic lifetime
  ## management — it runs to completion and cannot be cancelled
  ## externally. Wrap calls in `createRoot:` or a `spawn`'d task if
  ## you want cancel-on-dispose semantics.
  for a in frameAnimations:
    if a.target == s: a.cancelled = true
  result = Animation(
    kind: akTween,
    target: s,
    startVal: s.peek(),                   # no dep registration
    endVal: target,
    startMono: Moment.now(),
    duration: duration,
    easing: easing,
    originScope: currentScope)
  frameAnimations.add result
  # Tie lifetime to the registering scope: a scope dispose mid-tween
  # cancels the animation so it stops writing to a signal whose
  # observers may already be gone.
  let captured = result
  onCleanup proc() = captured.cancelled = true
  startFrameClock()

proc spring*(s: Signal[float], target: float,
             stiffness = 170.0, damping = 26.0,
             epsilonVel = 0.01, epsilonPos = 0.01): Animation
             {.discardable.} =
  ## Physics-based animation: a damped harmonic oscillator pulls `s`
  ## toward `target`. Defaults give ~500ms settle for a unit step,
  ## near-critical damping (no overshoot).
  ##
  ## Settle condition: |velocity| < `epsilonVel` AND
  ## |position - target| < `epsilonPos`. On settle, position snaps
  ## to exact target and the animation completes.
  ##
  ## **Retarget semantics:** if a spring or tween is already in flight
  ## against `s`, it's cancelled (last-write-wins). The new spring
  ## starts from `s`'s current value with velocity = 0. To preserve
  ## momentum from a prior in-flight spring, the caller would need
  ## a future `rtPreserve` opt-in — not in v3 since fresco's TUI
  ## use cases are state-transition-driven, not gesture-driven.
  ##
  ## Scope binding mirrors `tween`: a scope dispose mid-spring
  ## cancels via the onCleanup hook.
  for a in frameAnimations:
    if a.target == s: a.cancelled = true
  let now = Moment.now()
  result = Animation(
    kind: akSpring,
    target: s,
    springTarget: target,
    position: s.peek(),                   # start from current value
    velocity: 0.0,                        # fresh-start semantics
    stiffness: stiffness,
    damping: damping,
    epsilonVel: epsilonVel,
    epsilonPos: epsilonPos,
    lastTickMono: now,
    originScope: currentScope)
  frameAnimations.add result
  let captured = result
  onCleanup proc() = captured.cancelled = true
  startFrameClock()
