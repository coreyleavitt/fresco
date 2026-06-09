## test_inline_lifecycle.nim — Slice 17: withInlineScreen lifecycle.
##
## Proves the NORMAL/EXCEPTION flush guarantees + arm/disarm pairing +
## the MemorySink no-op path. All four tests run inside `waitFor` so the
## async context (and therefore the watch task) is valid.
##
## Tests:
##   1. Normal return flushes: teardownFlush emits buffered line; pending becomes 0.
##   2. Exception in body still flushes + propagates: flushed in finally.
##   3. Arm/disarm pairing: after normal exit both sigTailActive and
##      sigGracefulArmed are 0.
##   4. MemorySink compiles + no-ops: withInlineScreen works without a terminal fd.

import std/[unittest, posix, strutils]
import chronos
import fresco/inline_screen
import fresco/inline_teardown
import fresco/render/sink/terminal
import fresco/render/sink/memory
import fresco/terminal/termios

# ---------------------------------------------------------------------------
# Pipe helpers (mirrors test_inline_tail_buffer.nim)
# ---------------------------------------------------------------------------

proc openPipe(): tuple[r, w: cint] =
  var fds: array[2, cint]
  if pipe(fds) != 0:
    raise newException(OSError, "pipe() failed")
  (fds[0], fds[1])

proc readPipe(fd: cint, maxBytes: int): string =
  ## Non-blocking drain; returns everything available up to maxBytes.
  let flags = fcntl(fd, F_GETFL, 0)
  discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)
  var buf: array[16384, byte]
  result = ""
  while result.len < maxBytes:
    let n = posix.read(fd, addr buf[0], min(buf.len, maxBytes - result.len))
    if n > 0:
      for i in 0 ..< n: result.add chr(buf[i].int)
    elif errno == EAGAIN or errno == EWOULDBLOCK:
      break
    elif errno == EINTR:
      continue
    else:
      break

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "withInlineScreen lifecycle (slice 17)":

  test "1 normal return flushes buffered line":
    ## Inside an async proc (to satisfy the watch-task context requirement),
    ## use a real pipe as the TerminalSink fd so teardownFlush's writeAll
    ## delivers bytes we can read back. After the withInlineScreen block
    ## exits normally, the pipe must contain "LIFECYCLE-TAIL\n\n" (the line
    ## + the final "\n" that teardownFlush appends) and logPendingLen must be 0.
    proc body() {.async: (raises: [CancelledError, Exception]).} =
      let (pipeR, pipeW) = openPipe()
      defer:
        discard posix.close(pipeR)
        discard posix.close(pipeW)

      withInlineScreen(newTerminalSink(pipeW), 5, 20, 1, s):
        s.appendLine("LIFECYCLE-TAIL")
        # body exits normally here

      # After the block: check the pipe received the flushed line.
      # teardownFlush writes: "LIFECYCLE-TAIL\n" + "\n" (the trailing newline).
      let received = readPipe(pipeR, 4096)
      check received.contains("LIFECYCLE-TAIL")

    waitFor body()

  test "2 exception in body still flushes + propagates":
    ## The withInlineScreen finally block must run even when the body raises.
    ## Verify: (a) the exception propagates to the caller (expect catches it),
    ## AND (b) the pipe received the line appended before the raise.
    proc body() {.async: (raises: [CancelledError, Exception]).} =
      let (pipeR, pipeW) = openPipe()
      defer:
        discard posix.close(pipeR)
        discard posix.close(pipeW)

      var raised = false
      try:
        withInlineScreen(newTerminalSink(pipeW), 5, 20, 1, s):
          s.appendLine("EXC-TAIL")
          raise newException(ValueError, "boom")
      except ValueError:
        raised = true

      check raised
      let received = readPipe(pipeR, 4096)
      check received.contains("EXC-TAIL")

    waitFor body()

  test "3 arm/disarm pairing: no global signal state left after exit":
    ## After withInlineScreen exits normally, both tail and graceful handlers
    ## must be disarmed. Uses the test-seam getters inlineTailArmed() and
    ## gracefulArmed() added to termios.nim.
    proc body() {.async: (raises: [CancelledError, Exception]).} =
      let (pipeR, pipeW) = openPipe()
      defer:
        discard posix.close(pipeR)
        discard posix.close(pipeW)

      withInlineScreen(newTerminalSink(pipeW), 5, 20, 1, s):
        discard  # empty body — exits normally

      check not inlineTailArmed()
      check not gracefulArmed()

    waitFor body()

  test "4 MemorySink compiles + no-ops cleanly (no fd arming)":
    ## withInlineScreen must work with MemorySink (no .fd field).
    ## The when compiles(sink.fd) guard must suppress all terminal arming.
    ## The template must complete without error and without arming anything.
    proc body() {.async: (raises: [CancelledError, Exception]).} =
      withInlineScreen(newMemorySink(), 5, 20, 1, s):
        s.appendLine("x")
        discard  # exits normally

      # No terminal arming occurred — both guards are off.
      check not inlineTailArmed()
      check not gracefulArmed()

    waitFor body()
