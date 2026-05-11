## Animated signals — piecewise FRP behaviors with a frame clock.
##
##   tween(scroll, target = 100.0, 200.milliseconds, eEaseOutCubic)
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
    eLinear
    eEaseInQuad
    eEaseOutQuad
    eEaseInOutQuad
    eEaseInCubic
    eEaseOutCubic
    eEaseInOutCubic

  Animation* = ref object
    target: Signal[float]
    startVal, endVal: float
    startMono: Moment
    duration: Duration
    easing: Easing
    cancelled: bool

const DefaultFPS* = 30

var frameAnimations* {.threadvar.}: seq[Animation]
var frameClockTask {.threadvar.}: Future[void]
var frameInterval {.threadvar.}: Duration
  ## All three are thread-locals tied to the chronos dispatcher that
  ## first called `startFrameClock` (typically via `tween`). A `tween`
  ## issued from a different thread joins a list no clock is ticking,
  ## so its animation never advances. Single-dispatcher apps (the
  ## fresco default) are unaffected. Cross-thread animation would
  ## require a shared list + a per-thread clock — not yet implemented.

proc applyEasing*(t: float, e: Easing): float =
  let t = clamp(t, 0.0, 1.0)
  case e
  of eLinear:          t
  of eEaseInQuad:      t * t
  of eEaseOutQuad:     1.0 - (1.0 - t) * (1.0 - t)
  of eEaseInOutQuad:
    if t < 0.5: 2.0 * t * t
    else: 1.0 - pow(-2.0 * t + 2.0, 2) / 2.0
  of eEaseInCubic:     t * t * t
  of eEaseOutCubic:    1.0 - pow(1.0 - t, 3)
  of eEaseInOutCubic:
    if t < 0.5: 4.0 * t * t * t
    else: 1.0 - pow(-2.0 * t + 2.0, 3) / 2.0

proc step(a: Animation, now: Moment): bool =
  ## Advance one frame. Returns true when the animation completes.
  if a.cancelled: return true
  let elapsed = now - a.startMono
  if elapsed >= a.duration:
    a.target.set(a.endVal)
    return true
  let t = elapsed.nanoseconds.float / a.duration.nanoseconds.float
  let eased = applyEasing(t, a.easing)
  let v = a.startVal + (a.endVal - a.startVal) * eased
  a.target.set(v)
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
            duration: Duration, easing = eLinear): Animation
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
  for a in frameAnimations:
    if a.target == s: a.cancelled = true
  result = Animation(
    target: s,
    startVal: s.peek(),                   # no dep registration
    endVal: target,
    startMono: Moment.now(),
    duration: duration,
    easing: easing)
  frameAnimations.add result
  # Tie lifetime to the registering scope: a scope dispose mid-tween
  # cancels the animation so it stops writing to a signal whose
  # observers may already be gone.
  let captured = result
  onCleanup proc() = captured.cancelled = true
  startFrameClock()
