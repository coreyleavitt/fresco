## Child helper for test_inline_graceful_pty.nim.
##
## This program:
##   1. STDERR_FILENO is the PTY fd (runInPty wires all fds to the slave).
##   2. Builds an InlineScreen[TerminalSink] on STDERR_FILENO.
##   3. Inside withCbreak: arms the graceful teardown handler.
##   4. asyncSpawns watchTeardownSignals(s).
##   5. Appends two lines WITHOUT committing (buffered, pending).
##   6. Signals readiness to parent ("GRACE-READY").
##   7. Runs the chronos dispatcher long enough for the parent to signal.

import chronos
import std/[posix, termios as stdTermios]
import fresco/render/sink/terminal
import fresco/inline_screen
import fresco/inline_teardown
import fresco/terminal/termios as termiosMod

# Suppress ONLCR on STDERR so output bytes land verbatim on the PTY master.
var t: stdTermios.Termios
if tcGetAttr(STDERR_FILENO, addr t) == 0:
  t.c_oflag = t.c_oflag and not Cflag(ONLCR)
  discard tcSetAttr(STDERR_FILENO, TCSAFLUSH, addr t)

# Arm the static inline tail buffer for STDERR so the hard-path handler
# (double-signal escalation) also has something to flush.
termiosMod.armInlineTail(STDERR_FILENO)

proc runApp() {.async: (raises: [CancelledError, Exception]).} =
  # Build screen locally (avoids GC-safety global-capture issue).
  let sink = newTerminalSink(STDERR_FILENO)
  let s    = newInlineScreen(sink, 24, 80, pinnedHeaderRows = 1)

  withCbreak(STDIN_FILENO):
    # Layer the graceful handler on top of the hard termiosSignalHandler.
    armGracefulTeardown()

    # Spawn the watch task — fires when the self-pipe becomes readable.
    asyncSpawn watchTeardownSignals(s)

    # Buffer two lines WITHOUT committing — these are the lines teardownFlush
    # must emit in normal context.
    appendLine(s, "GRACE-TAIL-1")
    appendLine(s, "GRACE-TAIL-2")

    # Also arm the static tail buffer with the same content so the hard path
    # (double-signal escalation) can flush them too.
    termiosMod.setInlineTail(["GRACE-TAIL-1", "GRACE-TAIL-2"])

    # Signal readiness to the parent.
    let ready = "GRACE-READY\n"
    discard posix.write(STDERR_FILENO, unsafeAddr ready[0], ready.len)

    # Run the dispatcher long enough for the parent to send a signal.
    # 3000ms is plenty; parent signals at ~300ms.
    await sleepAsync(3000.milliseconds)

    # If we reach here (no signal), disarm cleanly.
    disarmGracefulTeardown()

waitFor runApp()
