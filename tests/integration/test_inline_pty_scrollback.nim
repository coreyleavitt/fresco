## test_inline_pty_scrollback.nim — Slice 13b PTY scrollback tests.
##
## Four tests covering the committed-scrollback contract over a real PTY pair:
##   (a) committed-before-repaint  — committed history emitted THEN live band repaints
##   (b) no-re-emit                — a committed line drained once is never re-emitted
##   (c) byte-order across resize  — committed order preserved across setSize
##   (d) teardown flushes tail     — teardownFlush emits uncommitted pending lines raw
##
## Uses the IN-PROCESS PTY idiom (established repo pattern):
##   openPtyPair() → use slave fd in-process → drainMasterMs(master, …)
##
## ONLCR gotcha: PTY slave applies OPOST/ONLCR by default (\n → \r\n).
## We put the slave into raw mode via cfmakeraw before writing so that
## output passes through unmodified and byte assertions stay clean.
##
## SIGTERM async-signal-safety note (test d):
##   The real SIGTERM path wires teardownFlush into the consumer's chronos
##   addSignal handler, which only WAKES the loop (async-signal-safe).
##   The loop then calls teardownFlush from normal (non-signal) context,
##   where draining heap strings + a write loop are safe. The fatal-signal
##   handler (slice 6b) does ONLY termios restore + alt-screen leave —
##   both async-signal-safe. This test exercises the explicit-call
##   contract directly, modelling the "synthetic SIGTERM after partial
##   emission still flushes the tail" path.

import std/unittest
import std/[posix, termios, strutils]
import fresco/inline_screen
import fresco/render/sink/terminal
import ./helpers/pty_subprocess

# cfmakeraw is in <termios.h> but Nim's std/termios may not expose it.
proc cfmakeraw(t: ptr Termios) {.importc: "cfmakeraw", header: "<termios.h>".}

proc makePtyScreen(h, w: int, pinnedHeaderRows = 1):
    tuple[s: InlineScreen[TerminalSink], master, slave: cint] =
  let (master, slave) = openPtyPair()
  # Put slave in raw mode to suppress OPOST/ONLCR (\n → \r\n) translation.
  var tio: Termios
  discard tcgetattr(slave, addr tio)
  cfmakeraw(addr tio)
  discard tcsetattr(slave, TCSANOW, addr tio)
  let sink = newTerminalSink(slave)
  let s = newInlineScreen(sink, h, w, pinnedHeaderRows)
  (s, master, slave)

suite "InlineScreen slice 13b: PTY committed-scrollback":

  test "(a) committed-before-repaint: committed lines emitted before live band":
    ## After commit(), the byte stream must contain committed lines BEFORE
    ## the live-band repaint bytes. The repaint emits a cursorTo for the
    ## region's row followed by the region content. We verify:
    ##   - stream contains "COMMITTED-A" and "COMMITTED-B"
    ##   - the index of "COMMITTED-A" in the stream is BEFORE the index of
    ##     the region's live content string.
    let (s, master, slave) = makePtyScreen(5, 20, pinnedHeaderRows = 1)
    defer:
      discard close(master)
      discard close(slave)

    let r = s.newRegion(0, 0, 4, 20)
    r.set(["LIVE-CONTENT"])
    r.markDirty()

    s.appendLine("COMMITTED-A")
    s.appendLine("COMMITTED-B")
    discard s.commit()

    let data = drainMasterMs(master, 200)

    check data.contains("COMMITTED-A")
    check data.contains("COMMITTED-B")
    check data.contains("LIVE-CONTENT")

    # Committed lines must appear BEFORE the live repaint.
    let idxA    = data.find("COMMITTED-A")
    let idxLive = data.find("LIVE-CONTENT")
    check idxA    >= 0
    check idxLive >= 0
    check idxA < idxLive

  test "(b) no-re-emit: first committed line not re-emitted on second commit":
    ## First commit drains "FIRST"; second commit drains "SECOND".
    ## d2 must contain "SECOND" and must NOT contain "FIRST".
    let (s, master, slave) = makePtyScreen(5, 20, pinnedHeaderRows = 1)
    defer:
      discard close(master)
      discard close(slave)

    s.appendLine("FIRST")
    discard s.commit()
    let d1 = drainMasterMs(master, 200)
    check d1.contains("FIRST")

    s.appendLine("SECOND")
    discard s.commit()
    let d2 = drainMasterMs(master, 200)
    check d2.contains("SECOND")
    check not d2.contains("FIRST")

  test "(c) byte order across width-change + commit is stable":
    ## Commit "BEFORE", setSize to narrower width, commit "AFTER".
    ## Both must appear and "BEFORE" must precede "AFTER" (committed
    ## order preserved across resize; no corruption/interleave).
    let (s, master, slave) = makePtyScreen(5, 20, pinnedHeaderRows = 1)
    defer:
      discard close(master)
      discard close(slave)

    s.appendLine("BEFORE")
    discard s.commit()
    let d1 = drainMasterMs(master, 200)

    s.setSize(5, 10)  # narrower

    s.appendLine("AFTER")
    discard s.commit()
    let d2 = drainMasterMs(master, 200)

    # Both strings present (may come from separate drain passes).
    let combined = d1 & d2
    check combined.contains("BEFORE")
    check combined.contains("AFTER")

    # "BEFORE" must precede "AFTER" in the combined chronological stream.
    let idxBefore = combined.find("BEFORE")
    let idxAfter  = combined.find("AFTER")
    check idxBefore >= 0
    check idxAfter  >= 0
    check idxBefore < idxAfter

  test "(d) teardown flushes buffered tail (models explicit teardown from SIGTERM handler)":
    ## appendLine twice WITHOUT committing — lines stay in pending.
    ## teardownFlush drains them all via raw writeAll (line + "\n") + final "\n".
    ## After the call, logPendingLen() == 0 and the stream contains both lines.
    ##
    ## SIGTERM async-signal-safety: the real path wires teardownFlush into
    ## a chronos addSignal handler that only wakes the loop; teardownFlush
    ## itself is called from normal loop context (not from the signal handler).
    let (s, master, slave) = makePtyScreen(5, 20, pinnedHeaderRows = 1)
    defer:
      discard close(master)
      discard close(slave)

    s.appendLine("TAIL-1")
    s.appendLine("TAIL-2")
    check s.logPendingLen() == 2

    s.teardownFlush()

    let data = drainMasterMs(master, 200)

    check s.logPendingLen() == 0
    check data.contains("TAIL-1")
    check data.contains("TAIL-2")
    # TAIL-1 must precede TAIL-2 (raw emission preserves append order).
    let idx1 = data.find("TAIL-1")
    let idx2 = data.find("TAIL-2")
    check idx1 >= 0
    check idx2 >= 0
    check idx1 < idx2
