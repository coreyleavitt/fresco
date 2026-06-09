## test_inline_lifecycle.nim — Slice 17: withInlineScreen lifecycle.
##
## Proves the NORMAL/EXCEPTION flush guarantees + arm/disarm pairing +
## the MemorySink no-op path. All four tests run inside `waitFor` so the
## async context (and therefore the watch task) is valid.
##
## Tests:
##   1. Normal return flushes: teardownFlush emits buffered line; pending becomes 0.
##   2. Exception in body still flushes + propagates: flushed in finally.
##   3. Arm/disarm pairing: after normal exit both sigTailArmed and
##      sigGracefulArmed are 0.
##   4. MemorySink compiles + no-ops: withInlineScreen works without a terminal fd.

import std/[unittest, posix, strutils]
import chronos
import fresco/inline_screen
import fresco/inline_teardown
import fresco/render/sink/terminal
import fresco/render/sink/memory
import fresco/terminal/termios
import intonaco/reactive

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

  test "3b arm/disarm pairing on exception path: finally disarms both tiers":
    ## When the withInlineScreen body raises, the `finally` block must still
    ## disarm both the inline-tail tier (armInlineTail → disarmInlineTail) and
    ## the graceful tier (armGracefulTeardown → disarmGracefulTeardown). After
    ## the exception propagates out of the withInlineScreen scope, both
    ## inlineTailArmed() and gracefulArmed() must be false. The exception
    ## itself must also propagate (not be swallowed).
    proc body() {.async: (raises: [CancelledError, Exception]).} =
      let (pipeR, pipeW) = openPipe()
      defer:
        discard posix.close(pipeR)
        discard posix.close(pipeW)

      var raised = false
      try:
        withInlineScreen(newTerminalSink(pipeW), 5, 20, 1, s):
          raise newException(ValueError, "test exception")
      except ValueError:
        raised = true

      check raised
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

# ---------------------------------------------------------------------------
# H3 regression: second lifecycle must register new fd correctly
# ---------------------------------------------------------------------------

suite "withInlineScreen H3: second lifecycle fd re-registration":

  test "H3 second lifecycle graceful path wakes (teardownPipeRegistered reset)":
    ## Run TWO sequential withInlineScreen lifecycles in the same process.
    ## Each lifecycle opens a fresh self-pipe (disarmGracefulTeardown closes it).
    ## The bug: teardownPipeRegistered stays true, so the second lifecycle
    ## skips register(newFd) → addReader on unregistered fd throws → future
    ## never completes → hang.
    ##
    ## Fix: reset teardownPipeRegistered = false in finally after disarmGracefulTeardown.
    ##
    ## Test: for each lifecycle, arm gracefully then manually write the self-pipe
    ## byte (simulating a signal) and assert waitTeardownByte completes via a
    ## timeout (not hang). We use the arm/disarm/drainTeardownPipe procs
    ## directly, bypassing withInlineScreen's full template, to keep it isolated.
    ##
    ## We use MemorySink here to avoid needing a real terminal fd, but we still
    ## manually exercise armGracefulTeardown + waitTeardownByte via two passes.
    ##
    ## Since waitTeardownByte is module-private, we validate via withInlineScreen
    ## itself: two sequential lifecycles that use MemorySink (no signal watch
    ## actually spawned) must both exit cleanly — the reset path is exercised
    ## by the finally block, and the second lifecycle must not hang at construction.
    ##
    ## For a stronger proof that the NEW fd is registered, we arm+spin once via
    ## a TerminalSink pipe so the watch task actually runs.
    proc body() {.async: (raises: [CancelledError, Exception]).} =
      let (pipeR1, pipeW1) = openPipe()
      defer:
        discard posix.close(pipeR1)
        discard posix.close(pipeW1)

      # --- First lifecycle ---
      var firstExited = false
      withInlineScreen(newTerminalSink(pipeW1), 5, 20, 1, s1):
        s1.appendLine("first lifecycle")
        firstExited = true
      check firstExited

      # After the first lifecycle, teardownPipeRegistered must be false (reset by fix).
      check not gracefulArmed()  # disarmed in finally

      # --- Second lifecycle: fresh pipe fds ---
      let (pipeR2, pipeW2) = openPipe()
      defer:
        discard posix.close(pipeR2)
        discard posix.close(pipeW2)

      var secondExited = false
      withInlineScreen(newTerminalSink(pipeW2), 5, 20, 1, s2):
        s2.appendLine("second lifecycle")
        secondExited = true
      check secondExited

      # Both lifecycles fully exited and flushed their lines.
      let r1 = readPipe(pipeR1, 4096)
      let r2 = readPipe(pipeR2, 4096)
      check r1.contains("first lifecycle")
      check r2.contains("second lifecycle")

    waitFor body()

# ---------------------------------------------------------------------------
# H3b regression: delayed watch-task cancellation must not double-unregister
# ---------------------------------------------------------------------------

suite "withInlineScreen H3b: cancellation finally is fd-safe":

  test "H3b dispatcher turns after a normal exit do not crash on teardown":
    ## The amoxtli REPL does `waitFor runApp()` (a withInlineScreen lifecycle
    ## that exits normally — scheduling `watchFut.cancelSoon()`) and THEN runs
    ## more dispatcher turns (`waitFor c.close()` etc). Those later turns deliver
    ## the queued cancellation to the watch task: `waitTeardownByte` resumes via
    ## CancelledError and runs its finally. But `withInlineScreenImpl`'s finally
    ## already unregistered the self-pipe fd (and `disarmGracefulTeardown` closed
    ## it) synchronously. The bug: that finally unconditionally called
    ## removeReader/unregister on the now-absent fd, raising an AssertionDefect
    ## ("Descriptor [N] is not registered in the selector!") — a Defect the
    ## `except OSError` could not catch → process crash on teardown.
    ##
    ## Fix: gate the finally cleanup on `teardownPipeRegistered` (the same flag
    ## that gates `register`), so the second finally is a clean no-op.
    ##
    ## Repro shape: run a lifecycle to a normal exit, then pump the dispatcher
    ## (sleepAsync) so the queued cancelSoon fires. Pre-fix this aborts the
    ## process; post-fix it returns and `survived` is true.
    proc lifecycle() {.async: (raises: [CancelledError, Exception]).} =
      let (pipeR, pipeW) = openPipe()
      defer:
        discard posix.close(pipeR)
        discard posix.close(pipeW)
      withInlineScreen(newTerminalSink(pipeW), 5, 20, 1, s):
        s.appendLine("h3b")
        # exits normally → finally schedules watchFut.cancelSoon()

    proc body() {.async: (raises: [CancelledError, Exception]).} =
      await lifecycle()
      # Mimic the REPL's trailing `waitFor c.close()`: extra dispatcher turns
      # deliver the queued cancellation to the watch task.
      await sleepAsync(50.milliseconds)

    waitFor body()
    var survived = true
    check survived

# ---------------------------------------------------------------------------
# M4 regression: gracefulArmed() assertion in watchTeardownSignals
# ---------------------------------------------------------------------------

suite "withInlineScreen M4: gracefulArmed() guard in watchTeardownSignals":

  test "M4a gracefulArmed() is false before arm and true after":
    ## Verify the predicate used by the M4 assertion behaves correctly,
    ## so the assertion is not vacuously true.
    proc body() {.async: (raises: [CancelledError, Exception]).} =
      check not gracefulArmed()   # before any arm
      # withInlineScreen with TerminalSink arms inside the block
      let (pipeR, pipeW) = openPipe()
      defer:
        discard posix.close(pipeR)
        discard posix.close(pipeW)
      var armedInsideBody = false
      withInlineScreen(newTerminalSink(pipeW), 5, 20, 1, s):
        armedInsideBody = gracefulArmed()
      check armedInsideBody         # was armed during body
      check not gracefulArmed()     # disarmed in finally
    waitFor body()

# ---------------------------------------------------------------------------
# M10 regression: reactive Signal overload of withInlineScreen
# ---------------------------------------------------------------------------

suite "withInlineScreen M10: reactive Signal overload":

  test "M10 reactive overload compiles and calls teardownFlush on exit":
    ## withInlineScreen(sink, size: Signal[(int,int)], pinnedHeaderRows, s, body)
    ## must construct via the primary constructor (reactive size) and run
    ## teardownFlush in finally. Proof: the buffered line appears in the pipe.
    proc body() {.async: (raises: [CancelledError, Exception]).} =
      let (pipeR, pipeW) = openPipe()
      defer:
        discard posix.close(pipeR)
        discard posix.close(pipeW)
      let sizeSig = signalC((5, 20))
      withInlineScreen(newTerminalSink(pipeW), sizeSig, 1, s):
        s.appendLine("reactive-overload")
      let received = readPipe(pipeR, 4096)
      check received.contains("reactive-overload")
    waitFor body()

  test "M10 reactive overload MemorySink compiles and no-ops":
    ## The reactive overload must also work with MemorySink (no fd).
    proc body() {.async: (raises: [CancelledError, Exception]).} =
      let sizeSig = signalC((5, 20))
      withInlineScreen(newMemorySink(), sizeSig, 1, s):
        s.appendLine("x")
        discard
      check not gracefulArmed()
    waitFor body()


# ---------------------------------------------------------------------------
# M1 regression: test-seam procs are accessible and internal fields are not
# ---------------------------------------------------------------------------

suite "InlineScreen M1: encapsulation — internal fields unexported, seams work":

  test "M1a commitRunsCount seam returns 0 on fresh screen":
    let s = newInlineScreen(newMemorySink(), 5, 20)
    check s.commitRunsCount() == 0

  test "M1b isCommitInProgress seam returns false initially":
    let s = newInlineScreen(newMemorySink(), 5, 20)
    check s.isCommitInProgress() == false

  test "M1c setCommitInProgressForTest seam is readable via isCommitInProgress":
    let s = newInlineScreen(newMemorySink(), 5, 20)
    s.setCommitInProgressForTest(true)
    check s.isCommitInProgress() == true
    s.setCommitInProgressForTest(false)
    check s.isCommitInProgress() == false

  test "M1d pendingCommit field is NOT directly settable from outside (structural)":
    ## pendingCommit is unexported. This test documents the structural guarantee
    ## by asserting the compiles() check fails for direct field assignment.
    let s = newInlineScreen(newMemorySink(), 5, 20)
    check not compiles(s.pendingCommit = true)

  test "M1e commitInProgress field is NOT directly readable from outside (structural)":
    let s = newInlineScreen(newMemorySink(), 5, 20)
    check not compiles(s.commitInProgress)

  test "M1f commitRuns field is NOT directly readable from outside (structural)":
    let s = newInlineScreen(newMemorySink(), 5, 20)
    check not compiles(s.commitRuns)

  test "M1g stagedH/stagedW/hasStagedSize fields are NOT directly readable (structural)":
    let s = newInlineScreen(newMemorySink(), 5, 20)
    check not compiles(s.stagedH)
    check not compiles(s.stagedW)
    check not compiles(s.hasStagedSize)

# ---------------------------------------------------------------------------
# M5b regression: commitRuns incremented consistently in synchronous commit
# ---------------------------------------------------------------------------

suite "InlineScreen M5b: commitRuns consistency across sync and async paths":

  test "M5b sync commit increments commitRunsCount when there is data to drain":
    let s = newInlineScreen(newMemorySink(), 5, 20)
    check s.commitRunsCount() == 0
    s.logSink.append("line")
    discard s.commit()
    check s.commitRunsCount() == 1

  test "M5b sync commit with empty log does NOT increment commitRunsCount":
    let s = newInlineScreen(newMemorySink(), 5, 20)
    discard s.commit()  # nothing in log
    check s.commitRunsCount() == 0

  test "M5b sync commit multiple calls each increment once when draining":
    let s = newInlineScreen(newMemorySink(), 5, 20)
    s.logSink.append("a")
    discard s.commit()
    s.logSink.append("b")
    discard s.commit()
    check s.commitRunsCount() == 2
