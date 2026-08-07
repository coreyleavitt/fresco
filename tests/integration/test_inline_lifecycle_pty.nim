## test_inline_lifecycle_pty.nim — R3-2 (round-3 stage-4): watchTeardownSignals
## must restore termios even when teardownFlush re-raises a captured Defect.
##
## Tier-2 (opens a real PTY slave via posix_openpt/grantpt/unlockpt/ptsname —
## tcGetAttr/tcSetAttr need a genuine tty; a plain pipe fails). Moved out of
## tests/unit/test_inline_lifecycle.nim (R4-1, round-4 stage-4 code review):
## it was the sole PTY-opening suite sitting in the unit tier, violating the
## documented taxonomy (AGENTS.md: unit = pure, PTY = integration). The
## sibling R3-3/R3-4 suites use MemorySink / a TerminalSink-on-pipe (never a
## PTY) and stayed behind in test_inline_lifecycle.nim.
##
## watchTeardownSignals used to call `teardownFlush(s)` with no guard at all,
## then `restoreAllAndReraise(...)`. Since H2 made teardownFlush able to
## re-raise a pending Defect (a Defect the async commit driver captured
## earlier), an unguarded raise there skipped restoreAllAndReraise entirely —
## chronos's async-macro Defect handler re-raises Defects EAGERLY right where
## they're caught (asyncmacro.nim's `addDefect`), so the exception flew
## straight past tier-2 termios restore on the FIRST graceful SIGTERM/SIGINT.
## Fixed by `completeGracefulTeardown` (inline_teardown.nim): drain, ALWAYS
## restore (`restoreAll`), then either re-raise the captured Defect (it
## supersedes the signal) or re-deliver the signal (`reraiseSignal`).
##
## This suite needs a REAL tty (a plain pipe fails tcGetAttr/tcSetAttr), so
## it opens a PTY slave directly rather than going through a fork+PTY child
## process — completeGracefulTeardown's Defect branch never reaches
## reraiseSignal's real `kill(getpid(), sig)`, so calling it in-process is
## safe as long as the Defect branch is the one exercised (which it always
## is here, by construction of the stale-band recipe below).

import std/[unittest, posix, termios as stdTermios]
import chronos
import fresco/inline_screen
import fresco/inline_teardown
import fresco/render/sink/terminal
import fresco/terminal/termios
import ./helpers/pty_primitives

proc lflagBits(fd: cint): stdTermios.Cflag =
  var t: stdTermios.Termios
  doAssert stdTermios.tcGetAttr(fd, addr t) == 0
  t.c_lflag

suite "withInlineScreen R3-2: watchTeardownSignals restores termios before a captured Defect propagates":

  test "completeGracefulTeardown restores termios and disarms BEFORE the Defect reaches the caller":
    proc body() {.async: (raises: [CancelledError, Exception]).} =
      let ptyFd = openPtySlave()
      defer: discard posix.close(ptyFd)

      let before = lflagBits(ptyFd)
      check (before and stdTermios.Cflag(ICANON)) != 0  # cooked mode initially

      withCbreak(ptyFd):
        check not gracefulArmed()
        armGracefulTeardown()
        check gracefulArmed()

        let raw = lflagBits(ptyFd)
        check (raw and stdTermios.Cflag(ICANON)) == 0  # now in raw/cbreak mode

        let sink = newTerminalSink(ptyFd)
        let s = newInlineScreen(sink, 10, 40)
        let r = s.newRegion(1, 0, 9, 40)
        doAssert r.row + r.height == s.layout.height

        # Prime a pendingDefect via the REAL async-capture path (the same
        # stale-band recipe used throughout the H2/R2-M1/R3-1 suites) so
        # teardownFlush re-raises when completeGracefulTeardown drains it.
        s.setSize(15, 40)  # grow, no reanchor: band now stale
        s.appendLine("R3-2 tail")
        await sleepAsync(20.milliseconds)  # let driveCommitStep capture it

        var raisedDefect = false
        try:
          completeGracefulTeardown(s, SIGTERM)
        except BandNotBottomAnchoredDefect:
          raisedDefect = true

        check raisedDefect
        # These run BEFORE withCbreak's own finally (still inside its body),
        # so they can only pass if completeGracefulTeardown's restoreAll —
        # not withCbreak's belt-and-suspenders finally — already ran.
        check not gracefulArmed()
        check lflagBits(ptyFd) == before

    waitFor body()
