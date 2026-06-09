## AltScreen — alternate-screen-buffer ownership lifecycle.
##
## AltScreen[S] wraps the existing Layout + Sink render machinery (the
## same machinery Screen[S] uses) and adds the ownership lifecycle for
## the terminal alternate-screen buffer:
##
##   enter()  → emits ?1049h then invalidates the sink (so first paint
##              redraws the entire fresh alt buffer from scratch).
##   leave()  → emits ?1049l (restoring the normal screen buffer).
##
## Rendering is identical to Screen[S]: Layout tracks regions + dirty
## state, Sink.commit emits ANSI diffs. AltScreen composes Layout + Sink
## directly (HAS-A, not IS-A) matching the RFC's "distinct named type"
## requirement.
##
## SIGWINCH / resize: call `setSize(s, h, w)` exactly as you would for
## Screen[S]. For AltScreen there is no live-zone arithmetic — resize
## just invalidates the sink and re-marks all regions, then a paint
## redraws the full surface. The same `watchResizes` / `installResizeHandler`
## machinery from screen.nim works: wire it to `setSize(s, ...)`.

import ./render/layout
import ./render/sink
import ./render/sink/terminal
import ./terminal/ansi
import ./terminal/altscreen_cap
import ./terminal/termios as termios_mod
import intonaco/reactive
import std/posix

export termios_mod.withCbreak

export layout.Region, layout.set, layout.markDirty, layout.setRow,
       layout.scrollUp, layout.rows, layout.resizeRows, layout.reclipRows

type
  AltScreen*[S: Sink] = ref object
    layout*:  Layout
    sink*:    S
    size*:    Signal[(int, int)]
      ## Reactive view of (height, width). Driven by `setSize` exactly
      ## as on Screen[S]. Subscribe to this instead of polling dimensions.

# ---------------------------------------------------------------------------
# Constructors
# ---------------------------------------------------------------------------

proc newAltScreen*[S: Sink, C: GrantsAltScreenCap](
    sink: S, size: Signal[(int, int)], cap: C): AltScreen[S] =
  ## Primary constructor. Accepts any witness satisfying GrantsAltScreenCap.
  ## The `cap` parameter is the compile-time gate: slice 5b will enforce
  ## the fail-fast-when-absent path; here we just thread the type through
  ## so call sites are already correctly shaped.
  let (h, w) = get(size)
  AltScreen[S](layout: newLayout(h, w), sink: sink, size: size)

proc newAltScreen*[S: Sink, C: GrantsAltScreenCap](
    sink: S, h, w: int, cap: C): AltScreen[S] =
  ## Static-size convenience: wraps a constant signal around (h, w).
  newAltScreen(sink, signalC((h, w)), cap)

# ---------------------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------------------

proc height*[S: Sink](s: AltScreen[S]): int {.inline.} = s.layout.height
proc width*[S: Sink](s: AltScreen[S]): int {.inline.}  = s.layout.width

proc newRegion*[S: Sink](s: AltScreen[S],
    row, col, height, width: int): Region =
  newRegion(s.layout, row, col, height, width)

# ---------------------------------------------------------------------------
# Enter / leave lifecycle
# ---------------------------------------------------------------------------

proc enter*[S: Sink](s: AltScreen[S]) =
  ## Emit ?1049h (switch to alt screen buffer) and invalidate the sink
  ## so the next paint redraws the entire surface. Call this once before
  ## the first paint tick.
  ##
  ## After the write succeeds, registers the fd in the signal-handler's
  ## async-signal-safe alt-screen state so SIGINT/SIGTERM emit ?1049l
  ## without heap allocation (raw write of a const byte buffer).
  mixin invalidate
  let seq = altScreenEnter()
  when S is TerminalSink:
    var written = 0
    while written < seq.len:
      let n = posix.write(s.sink.fd, unsafeAddr seq[written],
                          seq.len - written)
      if n > 0: written += n
      elif errno == EINTR: continue
      else: break
    termios_mod.markAltScreenEntered(s.sink.fd)
  s.sink.invalidate()

proc leave*[S: Sink](s: AltScreen[S]) =
  ## Emit ?1049l (restore normal screen buffer). Call on shutdown.
  ##
  ## Clears the signal-handler's alt-screen state BEFORE the write so
  ## a concurrent signal during leave does not double-emit ?1049l.
  when S is TerminalSink:
    termios_mod.markAltScreenLeft()
  let seq = altScreenLeave()
  when S is TerminalSink:
    var written = 0
    while written < seq.len:
      let n = posix.write(s.sink.fd, unsafeAddr seq[written],
                          seq.len - written)
      if n > 0: written += n
      elif errno == EINTR: continue
      else: break

# ---------------------------------------------------------------------------
# Paint
# ---------------------------------------------------------------------------

proc paint*[S: Sink](s: AltScreen[S]) =
  ## Commit the layout through the sink. Identical to Screen.paint.
  mixin commit
  s.sink.commit(s.layout)

proc flush*(s: AltScreen[TerminalSink]): string =
  ## Return the ANSI bytes for the current layout state without writing.
  ## Terminal-only (MemorySink has no byte representation to extract).
  s.sink.flush(s.layout)

# ---------------------------------------------------------------------------
# Exception-safe scope (slice 6a)
# ---------------------------------------------------------------------------

template withAltScreen*[S: Sink, C: GrantsAltScreenCap](
    sink: S, h, w: int, cap: C,
    screenIdent: untyped, body: untyped) =
  ## Exception-safe alternate-screen scope. fresco owns both teardown tiers:
  ##
  ##   tier-1 (normal / exception): `leave()` in `finally` — emits ?1049l
  ##     on every exit path including exception unwind.
  ##
  ##   tier-3 (SIGSEGV/crash): `withCbreak` installs `termiosSignalHandler`
  ##     for SIGINT/SIGTERM/SIGSEGV/SIGABRT/SIGBUS. The signal handler emits
  ##     the async-signal-safe ?1049l (via `markAltScreenEntered`, called from
  ##     `enter()`) and restores the saved termios before re-raising with
  ##     default disposition. AltScreen does NOT install a tier-2 graceful
  ##     self-pipe — that tier belongs to InlineScreen (which has a
  ##     ScrollbackLog to flush). AltScreen has no committed data to flush.
  ##
  ## Ordering rationale:
  ##   - `withCbreak` runs first so termiosSignalHandler is installed as the
  ##     innermost signal handler before `enter()` arms the alt-screen state.
  ##   - `newAltScreen` has no terminal side-effects; safe before `try`.
  ##   - `enter()` is the first statement *inside* `try` so that even a raise
  ##     from `enter` hits `finally`. `leave()` on a screen that never
  ##     completed `enter` is safe: it simply writes ?1049l, which is a
  ##     harmless no-op when ?1049h was never emitted.
  ##   - This closes the window where ?1049h is emitted but the `try` has not
  ##     yet begun (a construct-then-enter-outside-try ordering would leak the
  ##     alt buffer if enter raised between construction and try).
  ##
  ## Hygiene: `screenIdent` is injected into the body scope via
  ## `{.inject.}` so the caller can name the binding freely.
  ##
  ## Usage:
  ##   withAltScreen(sink, h, w, cap, s):
  ##     s.paint()
  let screenIdent {.inject.} = newAltScreen(sink, h, w, cap)
  withCbreak:
    try:
      screenIdent.enter()
      body
    finally:
      screenIdent.leave()

# ---------------------------------------------------------------------------
# Resize (SIGWINCH path)
# ---------------------------------------------------------------------------

proc setSize*[S: Sink](s: AltScreen[S], height, width: int) =
  ## Apply a new terminal size. Invalidates the sink, clamps/re-marks all
  ## regions, and updates the size signal — the same invariants as
  ## Screen.setSize but without liveZoneHeight arithmetic (alt screen
  ## owns the full surface).
  mixin invalidate
  s.layout.height = height
  s.layout.width  = width
  s.sink.invalidate()
  for r in s.layout.regions:
    if r.row >= height:
      r.height = 0
    elif r.row + r.height > height:
      r.height = height - r.row
    if r.col >= width:
      r.width = 0
    elif r.col + r.width > width:
      r.width = width - r.col
    r.resizeRows(r.height)
    r.reclipRows()
    r.pending = true
  s.size.set((height, width))
