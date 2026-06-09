## AltScreen — alternate-screen lifecycle + byte emission tests.
##
## Slice 5: verifies the ownership lifecycle of AltScreen[S]:
##   (a) enter emits ?1049h BEFORE the first paint bytes
##   (b) leave emits ?1049l AFTER the paint bytes
##   (c) resize (SIGWINCH/setSize) fires invalidate + full repaint
##
## Uses TerminalSink over a Unix pipe to capture exact bytes.

import std/[posix, strutils, unicode, unittest]
import fresco/screen
import fresco/altscreen
import fresco/render/layout
import fresco/render/sink/terminal
import fresco/render/sink/memory
import fresco/terminal/altscreen_cap
import fresco/terminal/ansi

# --- pipe helpers (mirrored from test_terminal_sink) ----------------------

proc readAvailable(fd: cint): string =
  var buf: array[4096, char]
  result = ""
  while true:
    let n = posix.read(fd, addr buf[0], buf.len)
    if n <= 0: break
    for i in 0 ..< n:
      result.add buf[i]
    if n < buf.len: break

proc setNonblock(fd: cint) =
  let flags = fcntl(fd, F_GETFL, 0)
  discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)

# A minimal witness type that satisfies GrantsAltScreenCap.
type AltCapWitness = object
  altScreenGrant: AltScreenGrant

# Convenience: build an AltScreen over a pipe-connected TerminalSink.
proc makeAltScreen(wr: cint, h, w: int): AltScreen[TerminalSink] =
  let sink = newTerminalSink(wr)
  newAltScreen(sink, h, w, AltCapWitness())

# -------------------------------------------------------------------------

suite "AltScreen: enter emits ?1049h before first paint bytes":

  test "enter sequence precedes cursor-positioning bytes":
    var pipefds: array[2, cint]
    doAssert pipe(pipefds) == 0
    let rd = pipefds[0]; let wr = pipefds[1]
    setNonblock(rd)
    defer:
      discard close(rd)
      discard close(wr)

    let s = makeAltScreen(wr, 3, 20)
    # enter + invalidate happen in the constructor; we must call
    # paint to flush bytes to the fd.
    let r = newRegion(s.layout, 0, 0, 3, 20)
    r.set(@["hello", "world", "!"])

    s.enter()
    s.paint()

    let bytes = readAvailable(rd)
    check altScreenEnter() in bytes
    check "hello" in bytes
    # ?1049h must appear BEFORE the content "hello".
    # (altScreenEnter itself starts with ESC[, so we use content position.)
    let enterPos = bytes.find(altScreenEnter())
    let helloPos = bytes.find("hello")
    check enterPos >= 0
    check helloPos > enterPos

suite "AltScreen: leave emits ?1049l after paint bytes":

  test "leave sequence follows paint content":
    var pipefds: array[2, cint]
    doAssert pipe(pipefds) == 0
    let rd = pipefds[0]; let wr = pipefds[1]
    setNonblock(rd)
    defer:
      discard close(rd)
      discard close(wr)

    let s = makeAltScreen(wr, 2, 20)
    let r = newRegion(s.layout, 0, 0, 2, 20)
    r.set(@["alpha", "beta"])

    s.enter()
    s.paint()
    s.leave()

    let bytes = readAvailable(rd)
    check altScreenLeave() in bytes
    check "alpha" in bytes
    # ?1049l must appear AFTER the content bytes.
    let leavePos = bytes.find(altScreenLeave())
    let alphaPos = bytes.find("alpha")
    check alphaPos < leavePos

suite "AltScreen: resize invalidates and triggers full repaint":

  test "setSize after a clean paint produces a full repaint":
    var pipefds: array[2, cint]
    doAssert pipe(pipefds) == 0
    let rd = pipefds[0]; let wr = pipefds[1]
    setNonblock(rd)
    defer:
      discard close(rd)
      discard close(wr)

    let s = makeAltScreen(wr, 3, 20)
    let r = newRegion(s.layout, 0, 0, 3, 20)
    r.set(@["row1", "row2", "row3"])

    s.enter()
    s.paint()
    discard readAvailable(rd)   # drain first paint

    # Now resize to the same dimensions (like Screen's test does).
    # Invalidate + re-mark regions → next paint should re-emit everything.
    setSize(s, 3, 20)
    s.paint()

    let after = readAvailable(rd)
    check after.len > 0         # full repaint emitted
    check "row1" in after

# ---------------------------------------------------------------------------
# H1 regression: width-shrink re-clip
# ---------------------------------------------------------------------------

suite "AltScreen: width-shrink setSize re-clips cached rows (H1)":

  test "rows wider than new width are clipped after setSize width-shrink":
    ## Regression for H1: before the fix, cached rows wider than the new
    ## width were left unchanged by setSize, causing them to bleed beyond
    ## the terminal column boundary on the next paint. After the fix,
    ## every row's displayWidth <= the new region width.
    var pipefds: array[2, cint]
    doAssert pipe(pipefds) == 0
    let rd = pipefds[0]; let wr = pipefds[1]
    setNonblock(rd)
    defer:
      discard close(rd)
      discard close(wr)

    let s = makeAltScreen(wr, 3, 40)
    let r = newRegion(s.layout, 0, 0, 3, 40)
    # Set content that fills the original 40-column width.
    r.set(@["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",   # 38 A's — fits in 40
            "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",   # 38 B's
            "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"])  # 38 C's
    s.enter()
    s.paint()
    discard readAvailable(rd)   # drain initial paint

    # Shrink width from 40 → 10.
    setSize(s, 3, 10)

    # All cached rows must now be <= 10 display columns (re-clip applied).
    for row in r.rows:
      check displayWidth(row) <= 10

  test "Screen.setSize width-shrink also re-clips cached rows":
    ## Same invariant for Screen[S] (the other consumer of the bug).
    ## Uses a MemorySink so there's no fd/pipe needed.
    let sink = newMemorySink()
    let s = newScreen(sink, 3, 40)
    let r = newRegion(s.layout, 0, 0, 3, 40)
    r.set(@["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
            "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"])
    s.paint()

    # Shrink width from 40 → 10.
    setSize(s, 3, 10)

    for row in r.rows:
      check displayWidth(row) <= 10
