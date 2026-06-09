## test_inline_trigger.nim — Slice 10c: pendingCommit trigger + commitInProgress
## gate + bounded-latency multi-batch drive.
##
## Integration tier (tests/integration/) because driving callSoon/asyncSpawn
## scheduling requires a live chronos dispatcher (waitFor).
##
## Tests:
##   (a) Exactly one run, no double-schedule.
##   (b) Zero-region InlineScreen still flushes.
##   (c) Auto-paint suppressed mid-commit (shouldAutoPaint predicate).
##   (d) Idempotency over a settled commit.

{.experimental: "callOperator".}

import std/unittest
import chronos
import fresco/inline_screen
import fresco/render/sink/memory
import intonaco/reactive

proc makeMemScreen(h, w: int, pinnedHeaderRows = 1): InlineScreen[MemorySink] =
  let sink = newMemorySink()
  newInlineScreen(sink, h, w, pinnedHeaderRows)

suite "InlineScreen slice 10c: trigger + gate + multi-batch drive":

  test "(a) exactly one run, no double-schedule":
    ## Append two lines back-to-back with no dispatcher turn between them.
    ## The second append's scheduleCommit call must be suppressed by the
    ## pendingCommit guard. After one dispatcher pass, commitRuns == 1
    ## and the log is empty.
    proc body() {.async: (raises: [Exception]).} =
      let s = makeMemScreen(5, 40)
      s.logSink.append("a")
      s.logSink.append("b")
      # Let the dispatcher run the scheduled driveCommit.
      await sleepAsync(5.milliseconds)
      check s.commitRuns == 1
      check s.logPendingLen() == 0
    waitFor body()

  test "(b) zero-region InlineScreen still flushes":
    ## An InlineScreen with no newRegion calls has anyPending==false.
    ## The trigger must be logPendingLen>0 (not anyPending), or the log
    ## buffers forever. liveZoneHeight > 0 (h=5, pinnedHeaderRows=1 → 4).
    proc body() {.async: (raises: [Exception]).} =
      let s = makeMemScreen(5, 20, pinnedHeaderRows = 1)
      # No regions allocated — anyPending(layout) is false.
      s.logSink.append("hello")
      await sleepAsync(5.milliseconds)
      check s.logPendingLen() == 0
    waitFor body()

  test "(c) auto-paint suppressed mid-commit":
    ## shouldAutoPaint returns false when commitInProgress is set even if
    ## a region is pending. Clears correctly when commitInProgress is false.
    ## Tests the gate predicate deterministically (no timer race).
    let s = makeMemScreen(5, 40)
    let r = s.newRegion(0, 0, 4, 40)
    r.set(["live content"])
    r.markDirty()  # ensure the region is pending

    s.commitInProgress = true
    check shouldAutoPaint(s) == false

    s.commitInProgress = false
    check shouldAutoPaint(s) == true

  test "(d) idempotency over a settled commit":
    ## After the first drive settles (commitRuns==1, log empty,
    ## commitInProgress false), append a third line and run the dispatcher.
    ## A fresh idle log must re-schedule and produce commitRuns==2.
    proc body() {.async: (raises: [Exception]).} =
      let s = makeMemScreen(5, 40)
      s.logSink.append("first")
      s.logSink.append("second")
      await sleepAsync(5.milliseconds)
      check s.commitRuns == 1
      check s.logPendingLen() == 0
      check s.commitInProgress == false

      s.logSink.append("third")
      await sleepAsync(5.milliseconds)
      check s.commitRuns == 2
      check s.logPendingLen() == 0
    waitFor body()
