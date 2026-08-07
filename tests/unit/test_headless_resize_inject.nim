## test_headless_resize_inject.nim — S0b: resize-injection seam in runHeadless
## InlineScreen overload.
##
## RED → GREEN cycle for RFC-0011 S0b.
##
## Proves that the headless harness can inject scripted terminal-resize events
## mid-run via a unified InlineEvent stream (Key | Resize), each applied via
## s.setSize(h, w) with one dispatcher turn to settle reactive updates before
## the next event. After settlement, s.liveZoneHeight() and s.layout.{height,
## width} must reflect the new dimensions.
##
## Tests:
##   1. InlineEvent type exists: Key and Resize variants compile.
##   2. Resize event mid-run updates liveZoneHeight before next Key is processed.
##   3. layout dimensions reflect the new size after resize event settles.
##   4. rows and committedRows are still captured correctly across a resize.
##   5. Existing @[] call site compiles unchanged (backward compat).

{.experimental: "callOperator".}

import std/[unittest, strutils]
import chronos
import intonaco/reactive
import fresco/inline_screen
import fresco/render/layout
import fresco/render/sink/memory
import fresco/headless/runner
import fresco/events
import fresco/input
import fresco/headless/input as headless_input

# ---------------------------------------------------------------------------
# Suite 1: InlineEvent type
# ---------------------------------------------------------------------------

suite "S0b: InlineEvent type":

  test "InlineEvent Key and Resize variants compile":
    ## The type must exist and both variants must be constructible.
    let ev1 = InlineEvent(kind: ievKey, key: atomKey(kEnter))
    let ev2 = InlineEvent(kind: ievResize, resizeH: 30, resizeW: 100)
    check ev1.kind == ievKey
    check ev2.kind == ievResize
    check ev2.resizeH == 30
    check ev2.resizeW == 100

  test "keyEv and resizeEv convenience constructors":
    let k = keyEv(atomKey(kEscape))
    let r = resizeEv(20, 60)
    check k.kind == ievKey
    check r.resizeH == 20

# ---------------------------------------------------------------------------
# Suite 2: resize injection via runHeadless InlineScreen overload
# ---------------------------------------------------------------------------

suite "S0b: resize injection via runHeadless":

  test "resize event updates liveZoneHeight mid-run":
    ## App observes liveZoneHeight at two points: before and after the resize
    ## event. Before: 24 - 1 = 23. After resize to 30 rows: 30 - 1 = 29.
    ##
    ## No region is allocated — the test targets only the reactive scalar.
    ## The app awaits a key as a sync point: the harness delivers it after
    ## the resize + one perKeySettle turn, so liveZoneHeight has settled.
    proc body() {.async: (raises: [Exception]).} =
      let sink = newMemorySink()
      let s = newInlineScreen(sink, 24, 80)
      # No region: we're only testing liveZoneHeight reactivity.

      var heightBefore = 0
      var heightAfter = 0

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        heightBefore = s.liveZoneHeight()
        # Wait for the key delivered after the resize + settle.
        let key = await stream.nextKey()
        heightAfter = s.liveZoneHeight()
        discard key

      # Script: resize to 30 rows (settle), then send a key so the app reads
      # heightAfter after liveZoneHeight has reacted.
      let events = @[
        resizeEv(30, 80),
        keyEv(atomKey(kEscape)),
      ]
      discard await runHeadless(s, app, events = events)

      check heightBefore == 23
      check heightAfter == 29  # 30 - 1

    waitFor body()

  test "layout dimensions reflect new size after resize event":
    ## After a resize event, s.layout.height and s.layout.width must equal
    ## the new dimensions.
    proc body() {.async: (raises: [Exception]).} =
      let sink = newMemorySink()
      let s = newInlineScreen(sink, 24, 80)

      var layoutHAfter = 0
      var layoutWAfter = 0

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        let key = await stream.nextKey()
        layoutHAfter = s.layout.height
        layoutWAfter = s.layout.width
        discard key

      let events = @[
        resizeEv(30, 120),
        keyEv(atomKey(kEscape)),
      ]
      discard await runHeadless(s, app, events = events)

      check layoutHAfter == 30
      check layoutWAfter == 120

    waitFor body()

  test "committedRows from pre-resize commit preserved; layout height updated":
    ## Lines committed (via s.commit()) BEFORE the resize event appear in
    ## HeadlessResult.committedRows. After the resize the layout height is
    ## 15, so result.rows (the MemorySink live-band snapshot) has 15 entries.
    ##
    ## Post-resize appendLine (without s.commit()) is deferred to a future
    ## test once S0c's relayout helper keeps the region bottom-anchored.
    proc body() {.async: (raises: [Exception]).} =
      let sink = newMemorySink()
      # Start at 10 rows, pinnedHeaderRows=1, liveZoneHeight=9.
      # Region at row 1, height 9: lowestEdge = 10 = layout.height ✓
      let s = newInlineScreen(sink, 10, 40)
      let r = s.newRegion(1, 0, 9, 40)

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        r.set(["initial live"])
        s.appendLine("before resize")
        discard s.commit()
        # Await the key delivered after the resize event.
        let key = await stream.nextKey()
        discard key
        # Do NOT appendLine or commit here: after resize the region is no
        # longer bottom-anchored (lowestEdge=10 < new height=15). Since H2
        # (round-1 stage-4), appendLine in this state is safe to call — the
        # async commit driver captures BandNotBottomAnchoredDefect instead of
        # letting it escape into chronos's dispatcher, and re-raises it
        # synchronously at the harness's own teardownFlush()/paint() call
        # (see the "H2" suite below for the deterministic repro + the
        # reanchored non-vacuity counterpart). This test stays a clean,
        # defect-free baseline for the plain resize-and-capture behavior;
        # post-resize log capture across a reanchor is covered by S0c
        # (test_inline_reanchor.nim) and the H2 suite below.

      let events = @[
        resizeEv(15, 40),
        keyEv(atomKey(kEscape)),
      ]
      let result = await runHeadless(s, app, events = events)

      check result.committedRows.contains("before resize")
      # paint() captures the layout at its new height.
      check result.rows.len == 15

    waitFor body()

  test "empty events seq still works (backward compat)":
    ## Existing call sites that pass events = @[] must continue to compile
    ## and behave as before: app runs, drain is final, committedRows captured.
    proc body() {.async: (raises: [Exception]).} =
      let sink = newMemorySink()
      let s = newInlineScreen(sink, 10, 40)
      let r = s.newRegion(1, 0, 9, 40)

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        r.set(["hello"])
        s.appendLine("line1")
        discard s.commit()

      let result = await runHeadless(s, app, events = @[])
      check result.committedRows.len == 1
      check result.committedRows[0] == "line1"
      check result.rows[1] == "hello"

    waitFor body()

  test "Key events in unified stream still drive the app":
    ## Pure key-only InlineEvent stream behaves identically to the old
    ## seq[KeyEvent] path: the app receives the keys and can act on them.
    proc body() {.async: (raises: [Exception]).} =
      let sink = newMemorySink()
      let s = newInlineScreen(sink, 10, 40)
      let r = s.newRegion(1, 0, 9, 40)

      var sawKey = false

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        let key = await stream.nextKey()
        if key.kind == kEscape:
          sawKey = true

      let events = @[keyEv(atomKey(kEscape))]
      discard await runHeadless(s, app, events = events)

      check sawKey

    waitFor body()

# ---------------------------------------------------------------------------
# Suite 3: H2 (round-1 stage-4) — BandNotBottomAnchoredDefect capture
# ---------------------------------------------------------------------------
#
# H2: the async commit driver (driveCommitStep, scheduled via
# scheduleCommit's callSoon) used to catch only CatchableError. A
# BandNotBottomAnchoredDefect raised inside commitOneBatch during that
# scheduled callback sailed straight through the {.raises: [].} callback
# into chronos's poll() (no Defect handler there) and killed the process
# on whatever dispatcher turn happened to run the callback — deterministic
# neither in timing nor in which test paid for it. Fixed by having
# driveCommitStep catch the Defect, store it on the screen, and have every
# relevant synchronous entry point (paint, LogSink.append/appendLine,
# teardownFlush, commit) re-raise it immediately.

suite "H2: BandNotBottomAnchoredDefect capture — does not escape into the dispatcher":

  test "resize WITHOUT reanchor + post-resize appendLine: Defect surfaces synchronously from runHeadless":
    ## Script: grow-resize (10 -> 15) with NO reanchor, then — once the
    ## trailing key event settles — the app calls appendLine. The band is
    ## now stale (lowestEdge=10 != new H=15).
    ##
    ## settleDrain is used deliberately: drainToIdle's dcDispatcher/dcCommit
    ## clauses force the pump to keep stepping until the async commit driver
    ## (scheduled by appendLine's LogSink.append -> notify -> scheduleCommit
    ## -> callSoon) actually RUNS before the per-event drain returns. That
    ## makes the repro deterministic instead of racing chronos's callback
    ## queue: pre-fix, BandNotBottomAnchoredDefect escapes uncaught from
    ## deep inside that pump (driveCommitStep -> the callSoon callback ->
    ## chronos poll(), which has no Defect handler) and crashes the process
    ## right there — or, absent a forced pump like this one, on whatever
    ## LATER dispatcher turn (possibly a different test) happens to run the
    ## stray callback. Post-fix, driveCommitStep captures the Defect instead
    ## of raising, and it resurfaces deterministically and synchronously at
    ## teardownFlush() (the harness's own end-of-run drain) — still inside
    ## THIS test's waitFor, never the dispatcher's.
    proc body() {.async: (raises: [Exception]).} =
      let sink = newMemorySink()
      let s = newInlineScreen(sink, 10, 40)  # pinnedHeaderRows=1 (default)
      let r = s.newRegion(1, 0, 9, 40)       # bottom-anchored: 1+9=10=H
      check r.row + r.height == s.layout.height

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        let key = await stream.nextKey()
        discard key
        # Region is now stale: lowestEdge=10, new H=15. No reanchor.
        s.appendLine("post-resize, no reanchor")

      let events = @[
        resizeEv(15, 40),
        keyEv(atomKey(kEscape)),
      ]
      discard await runHeadless(s, app, events = events, settle = settleDrain())

    expect BandNotBottomAnchoredDefect:
      waitFor body()

  test "resize WITHOUT reanchor + reanchorBottom before appendLine: clean run, no Defect (non-vacuity)":
    ## Companion positive test: identical script, except the app calls
    ## reanchorBottom right after observing the resize (before appendLine).
    ## Proves the H2 fix does not mask a REAL contract violation — a
    ## correctly-reanchored band still commits cleanly through the same
    ## async driver path that raises in the test above.
    proc body() {.async: (raises: [Exception]).} =
      let sink = newMemorySink()
      let s = newInlineScreen(sink, 10, 40)
      let r = s.newRegion(1, 0, 9, 40)

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        let key = await stream.nextKey()
        discard key
        reanchorBottom(s.layout, [r])
        s.appendLine("post-resize, reanchored")

      let events = @[
        resizeEv(15, 40),
        keyEv(atomKey(kEscape)),
      ]
      let result = await runHeadless(s, app, events = events, settle = settleDrain())
      check result.settled()
      check result.committedRows.contains("post-resize, reanchored")
      check r.row + r.height == s.layout.height

    waitFor body()

# ---------------------------------------------------------------------------
# Suite 4: R2-M1 (round-2 stage-4) — teardownFlush drains BEFORE re-raising
# a stashed Defect; a compound failure (app crash + captured Defect)
# supersedes result reporting in runHeadless.
# ---------------------------------------------------------------------------
#
# R2-M1: teardownFlush's re-raise of a pendingDefect used to be its FIRST
# statement, voiding its own "zero bytes dropped" drain guarantee whenever a
# Defect was pending (tail lines buffered since the capture were never
# drained). Fixed by moving the re-raise to the LAST statement — drain and
# disarm always run first. Test 1 proves the drain observably happens (the
# lines land in committedRows) even though teardownFlush still raises. Test
# 2 proves the documented precedence: a captured Defect supersedes
# HeadlessResult reporting even when the app ALSO crashed.

suite "R2-M1: teardownFlush drains pending lines before re-raising a stashed Defect":

  test "pendingDefect + pending tail lines: teardownFlush raises the Defect AND the drain happened first":
    ## Direct unit test of teardownFlush's internal ordering — no dispatcher
    ## turns involved. appendLine buffers two lines into the log (the async
    ## commit driver is only scheduled via callSoon, never actually run,
    ## since nothing here awaits/polls the dispatcher); setPendingDefectForTest
    ## stashes a Defect the way the real async driver would after capturing
    ## one. teardownFlush must still fully drain those buffered lines into
    ## sink.committedRows (the observable proof of "drain happened first")
    ## before re-raising the stashed Defect.
    let sink = newMemorySink()
    let s = newInlineScreen(sink, 10, 40)
    s.appendLine("line1")
    s.appendLine("line2")
    check s.logPendingLen() == 2  # nothing drained yet — no dispatcher turn ran

    let d = newException(BandNotBottomAnchoredDefect, "R2-M1 test defect")
    s.setPendingDefectForTest(d)

    expect BandNotBottomAnchoredDefect:
      s.teardownFlush()

    check sink.committedRows == @["line1", "line2"]
    check s.logPendingLen() == 0

  test "compound failure under runHeadless: app crashes AND a Defect is captured — the Defect propagates, not the HeadlessResult":
    ## Same stale-band recipe as the H2 suite above (resize w/o reanchor +
    ## post-resize appendLine under settleDrain, forcing the async driver to
    ## run and capture the Defect during the per-event drain) — except this
    ## app ALSO raises after the appendLine call, so BOTH facts are true:
    ## the app future fails AND a Defect is captured. Per the documented
    ## precedence (R2-M1): the captured Defect supersedes result reporting.
    ##
    ## R3-5 (round-3 stage-4: corrected — this used to say "runHeadless's own
    ## teardownFlush() call re-raises it," which is not what actually happens
    ## under settleDrain here): the keyEv event's own `await
    ## drainToIdle(screen, settle.drain)` call (in runHeadless's skDrain loop)
    ## is what surfaces it — its pump gives the app task the dispatcher turns
    ## it needs to wake from `nextKey()`, appendLine (scheduling the async
    ## commit driver), and raise; once every drain clause reads idle,
    ## `drainToIdle`'s own trailing `screen.paint()` postcondition re-raises
    ## the by-then-captured Defect. That raise is not a `DrainTimeoutError`,
    ## so the loop's `except DrainTimeoutError` does not catch it — it
    ## propagates straight out of `runHeadless`, well before the function
    ## ever reaches its final `teardownFlush()`/`paint()` lines, landing here
    ## rather than in a returned `HeadlessResult`.
    proc body() {.async: (raises: [Exception]).} =
      let sink = newMemorySink()
      let s = newInlineScreen(sink, 10, 40)
      let r = s.newRegion(1, 0, 9, 40)
      check r.row + r.height == s.layout.height

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        let key = await stream.nextKey()
        discard key
        # Region is now stale: lowestEdge=10, new H=15. No reanchor.
        s.appendLine("post-resize, no reanchor, then crash")
        raise newException(ValueError, "app crashed after triggering the stale band")

      let events = @[
        resizeEv(15, 40),
        keyEv(atomKey(kEscape)),
      ]
      discard await runHeadless(s, app, events = events, settle = settleDrain())

    expect BandNotBottomAnchoredDefect:
      waitFor body()

# ---------------------------------------------------------------------------
# Suite 5: R2-M4 (round-2 stage-4) — reraisePendingDefect's blessed entry
# points, tested individually.
# ---------------------------------------------------------------------------
#
# reraisePendingDefect's doc comment (inline_screen.nim) names four blessed
# entry points that re-raise a stored Defect: paint, the LogSink.append
# notify path, teardownFlush, and commit. Only teardown-path behavior was
# tested pre-round-2 (the H2/R2-M1 suites above, both via teardownFlush).
# This suite pins the other three individually; a comment on
# reraisePendingDefect itself points here as the test file that pins the
# entry-point set.
#
# Each test drives the same stale-band recipe (resize w/o reanchor +
# post-resize appendLine) directly against an InlineScreen[MemorySink] —
# no runHeadless involved — then pumps the dispatcher directly (a plain
# `sleepAsync`, NOT `drainToIdle`) until the async commit driver has
# genuinely captured the Defect, before exercising the entry point under
# test. `drainToIdle` cannot be used for this priming step: its own
# postcondition calls `screen.paint()` unconditionally once every clause
# reads idle, which would itself call `reraisePendingDefect` and consume
# the Defect the instant it's captured — leaving nothing pending for the
# test to exercise. (Confirmed empirically: swapping the sleep below for
# `await drainToIdle(s)` makes the Defect escape from INSIDE that call,
# via its internal `paint()` postcondition, instead of staying pending.)

suite "R2-M4: reraisePendingDefect's other blessed entry points":

  proc primeStaleBandDefect(): Future[InlineScreen[MemorySink]]
      {.async: (raises: [Exception]).} =
    ## Shared setup: build a 10x40 screen with a bottom-anchored region,
    ## resize (grow) WITHOUT reanchoring, append a line to trigger the
    ## async commit driver, then pump the dispatcher directly (no
    ## drainToIdle — see the suite comment above) until driveCommitStep has
    ## genuinely caught BandNotBottomAnchoredDefect and stored it as
    ## screen.pendingDefect, leaving it there for the test to exercise.
    let sink = newMemorySink()
    let s = newInlineScreen(sink, 10, 40)
    let r = s.newRegion(1, 0, 9, 40)
    doAssert r.row + r.height == s.layout.height

    s.setSize(15, 40)  # grow, no reanchor: band now stale
    s.appendLine("post-resize, no reanchor")  # schedules the async driver

    # R3-5 (round-3 stage-4): deterministic, not a race with the timer —
    # callSoon-scheduled callbacks (the async driver's) are always drained
    # from the dispatcher's callback queue before a positive-duration timer
    # (sleepAsync here) is allowed to complete, on every poll() turn. Any
    # positive duration works; 20ms is not a tuned/minimum value.
    await sleepAsync(20.milliseconds)  # let the callSoon-scheduled driver run

    result = s

  test "paint re-raises a pending Defect":
    proc body() {.async: (raises: [Exception]).} =
      let s = await primeStaleBandDefect()
      expect BandNotBottomAnchoredDefect:
        s.paint()

    waitFor body()

  test "LogSink.append (appendLine) re-raises a pending Defect":
    proc body() {.async: (raises: [Exception]).} =
      let s = await primeStaleBandDefect()
      expect BandNotBottomAnchoredDefect:
        s.appendLine("second line, after the capture")

    waitFor body()

  test "commit re-raises a pending Defect":
    proc body() {.async: (raises: [Exception]).} =
      let s = await primeStaleBandDefect()
      expect BandNotBottomAnchoredDefect:
        discard s.commit()

    waitFor body()

# ---------------------------------------------------------------------------
# Suite 6: R3-1 (round-3 stage-4) — commitOneBatch's bottom-anchor check must
# run BEFORE the destructive pop, or the popped batch is lost on the real
# capture path.
# ---------------------------------------------------------------------------
#
# R3-1: commitOneBatch used to call s.logDrainBatch(kCommitBatch) (a
# destructive pop off s.log.pending) BEFORE evaluating the bottom-anchor
# check that raises BandNotBottomAnchoredDefect. When driveCommitStep
# caught that Defect (the real async-capture path, not the
# setPendingDefectForTest seam), the already-popped batch was gone —
# never written anywhere, and no longer sitting in s.log.pending either —
# so teardownFlush's later drain could not recover it. The existing
# R2-M1 unit test only exercises the seam (stashes a Defect directly,
# never calls the real commitOneBatch), so it could not see this: the
# lines it asserts on were never popped by commitOneBatch in the first
# place. This test drives the REAL capture path (resize-without-reanchor
# + appendLine, pumped so driveCommitStep genuinely runs) and asserts the
# appended line survives into committedRows once teardownFlush drains it.

suite "R3-1: commitOneBatch's bottom-anchor check runs before the destructive pop":

  test "resize WITHOUT reanchor + appendLine: the popped batch is not lost when the async driver captures the Defect":
    proc body() {.async: (raises: [Exception]).} =
      let sink = newMemorySink()
      let s = newInlineScreen(sink, 10, 40)
      let r = s.newRegion(1, 0, 9, 40)
      doAssert r.row + r.height == s.layout.height

      s.setSize(15, 40)  # grow, no reanchor: band now stale
      s.appendLine("R3-1 not lost")  # schedules driveCommitStep via callSoon

      # Let the callSoon-scheduled driveCommitStep actually run and capture
      # the Defect via the REAL path (commitOneBatch raising inside the
      # async driver) — not the setPendingDefectForTest seam.
      await sleepAsync(20.milliseconds)

      var raisedDefect = false
      try:
        s.teardownFlush()
      except BandNotBottomAnchoredDefect:
        raisedDefect = true

      check raisedDefect
      # The line must have survived the commitOneBatch pop-then-raise and
      # been recovered by teardownFlush's own unconditional drain.
      check sink.committedRows == @["R3-1 not lost"]

    waitFor body()
