## test_inline_reanchor.nim — S0c: reanchorBottom helper + watchResizes(InlineScreen)
##
## RED → GREEN cycle for RFC-0011 S0c.
##
## Proves:
##   (a) reanchorBottom restacks band regions so max(r.row+r.height) == newH
##       after a grow resize (24→30) and a shrink resize (24→12).
##   (b) A post-resize appendLine + commit does NOT raise BandNotBottomAnchoredDefect
##       when reanchorBottom is called after the resize (the exact gap S0b documented).
##   (c) Shrink case where total band height exceeds new terminal height is clamped
##       gracefully (no negative rows, heights zeroed per applySizeNow convention).
##   (d) watchResizes(InlineScreen[TerminalSink]) compiles and has the same
##       loop structure as watchResizes(TerminalScreen).

{.experimental: "callOperator".}

import std/[unittest, posix]
import chronos
import intonaco/reactive
import fresco/inline_screen
import fresco/render/layout
import fresco/render/sink/memory
import fresco/render/sink/terminal
import fresco/screen

var SIGWINCH {.importc, header: "<signal.h>".}: cint

# ---------------------------------------------------------------------------
# Suite 1: reanchorBottom geometry — pure spatial arithmetic
# ---------------------------------------------------------------------------

suite "S0c: reanchorBottom geometry":

  test "grow resize: two regions re-anchored to new bottom":
    ## Start 24-row screen, two equal-height regions (12 rows each) touching
    ## the bottom. Grow to 30. After reanchorBottom: regions stack so that
    ## the lowest edge == 30 (each region stays 12 rows; combined top = 30-24=6).
    let sink = newMemorySink()
    let s = newInlineScreen(sink, 24, 80, pinnedHeaderRows = 0)
    # Allocate two 12-row regions that reach the bottom: rows 0..11 and 12..23.
    let r1 = s.newRegion(0,  0, 12, 80)
    let r2 = s.newRegion(12, 0, 12, 80)
    # Sanity: bottom-anchored at H=24.
    check r1.row + r1.height + r2.height == 24

    # Grow to 30.
    s.setSize(30, 80)
    # After grow, r1.row + r1.height = 12 ≠ 30 and r2 still at row 12.
    # Band is now NOT bottom-anchored (lowest edge = 12+12=24 ≠ 30).
    check (r1.row + r1.height) != 30 or (r2.row + r2.height) != 30  # gap exists

    # Re-anchor.
    reanchorBottom(s.layout, [r1, r2])

    # Post-condition: max(r.row + r.height) == newH == 30.
    check r2.row + r2.height == 30
    check r1.row + r1.height == r2.row  # r1 bottom edge == r2 top edge (contiguous)
    check r2.row + r2.height == s.layout.height

  test "shrink resize: two regions re-anchored to shrunken bottom":
    ## Start 24-row, two 9-row regions at rows 6 and 15 (bottom edge = 24).
    ## Shrink to 12. reanchorBottom: combined height=18 > 12 → clamp.
    ## Simplified: use two 6-row regions (combined=12, fits in 12).
    let sink = newMemorySink()
    let s = newInlineScreen(sink, 24, 80, pinnedHeaderRows = 0)
    let r1 = s.newRegion(12, 0, 6, 80)
    let r2 = s.newRegion(18, 0, 6, 80)
    check r2.row + r2.height == 24  # bottom-anchored initially

    # Shrink to 12: applySizeNow clamps r1 (row=12 >= 12 → height=0),
    # and r2 (row=18 >= 12 → height=0). Both zeroed.
    s.setSize(12, 80)
    check r1.height == 0
    check r2.height == 0

    # reanchorBottom with zeroed heights: sum=0, startRow=12. rows assigned
    # sequentially from 12 but nothing to place. No panic.
    reanchorBottom(s.layout, [r1, r2])
    # With heights zeroed there is no meaningful "lowest edge" to assert,
    # but the call must not crash and rows must be >= 0.
    check r1.row >= 0
    check r2.row >= 0

  test "grow resize: single region re-anchored to new bottom":
    ## Single-region band: one region of height 5 at row 19 (bottom=24).
    ## Grow to 30. After reanchorBottom: row = 30-5 = 25; bottom = 30.
    let sink = newMemorySink()
    let s = newInlineScreen(sink, 24, 80, pinnedHeaderRows = 0)
    let r = s.newRegion(19, 0, 5, 80)
    check r.row + r.height == 24

    s.setSize(30, 80)
    # height unchanged (row=19 < 30, row+height=24 <= 30: no clamp).
    check r.height == 5
    # But band is now NOT bottom-anchored.
    check r.row + r.height != 30

    reanchorBottom(s.layout, [r])

    check r.row == 30 - 5   # == 25
    check r.row + r.height == 30
    check r.row + r.height == s.layout.height

  test "zero regions: reanchorBottom is a no-op":
    ## No regions → no-op, no crash.
    let sink = newMemorySink()
    let s = newInlineScreen(sink, 24, 80, pinnedHeaderRows = 0)
    reanchorBottom(s.layout, newSeq[Region]())
    check s.layout.height == 24   # unchanged

# ---------------------------------------------------------------------------
# Suite 2: reanchorBottom enables post-resize commit without Defect
# ---------------------------------------------------------------------------

suite "S0c: post-resize commit after reanchorBottom":

  test "grow: appendLine + commit succeeds after reanchorBottom":
    ## The exact gap S0b documented: after a grow resize, the region's
    ## lowestEdge < newH, so commitOneBatch raises BandNotBottomAnchoredDefect.
    ## Calling reanchorBottom before commit fixes this.
    let sink = newMemorySink()
    let s = newInlineScreen(sink, 24, 80, pinnedHeaderRows = 1)
    # pinnedHeaderRows=1 → liveZoneHeight=23 initially.
    # Bottom-anchored: region at row 1, height 23 → lowestEdge = 1+23 = 24 = H. ✓
    let r = s.newRegion(1, 0, 23, 80)
    check r.row + r.height == 24

    # Grow to 30.
    s.setSize(30, 80)
    # r.row still 1, r.height still 23 (no clamp: 1+23=24 <= 30).
    check r.height == 23
    # lowestEdge = 1+23 = 24 ≠ 30 → BandNotBottomAnchoredDefect if we commit now.

    # Re-anchor BEFORE commit.
    reanchorBottom(s.layout, [r])
    check r.row + r.height == 30  # now bottom-anchored

    # Commit must NOT raise.
    s.appendLine("post-resize line")
    let bytes = s.commit()
    # MemorySink path returns "" from commitOneBatch (falls back to paint).
    # The key check: no exception was raised.
    check s.logPendingLen() == 0  # log was drained

  test "shrink: region fits after shrink, reanchorBottom + commit ok":
    ## Shrink from 24 to 20. Region height=5 at row 19 → row+height=24>20 → clamped.
    ## After clamp: r.height reduced. Restore anchoring then commit.
    let sink = newMemorySink()
    # pinnedHeaderRows=0 so liveZoneHeight = H for simplicity.
    let s = newInlineScreen(sink, 24, 80, pinnedHeaderRows = 0)
    let r = s.newRegion(19, 0, 5, 80)
    check r.row + r.height == 24

    # Shrink to 20. r.row=19 < 20, r.row+r.height=24 > 20 → r.height clamped to 1.
    s.setSize(20, 80)
    check r.height == 1  # 20 - 19 = 1

    # Re-anchor: single region of height 1 → row = 20-1 = 19, bottom = 20.
    reanchorBottom(s.layout, [r])
    check r.row + r.height == 20
    check r.row + r.height == s.layout.height

    s.appendLine("post-shrink line")
    discard s.commit()
    check s.logPendingLen() == 0

  test "WITHOUT reanchorBottom, grow resize trips BandNotBottomAnchoredDefect":
    ## Regression guard: confirms the defect IS raised WITHOUT the helper,
    ## so the test above is testing the actual gap and not a vacuous pass.
    ##
    ## Note: directly enqueue via logSink.append (bypasses scheduleCommit)
    ## then call synchronous commit(). After catching the Defect, reset
    ## commitInProgress via the frescoTesting seam so the callSoon callback
    ## that fires on the next dispatcher turn does not re-raise as an
    ## unhandled Defect and corrupt subsequent test state.
    let sink = newMemorySink()
    let s = newInlineScreen(sink, 24, 80, pinnedHeaderRows = 1)
    let r = s.newRegion(1, 0, 23, 80)
    s.setSize(30, 80)
    # r.height still 23, lowestEdge = 1+23 = 24 ≠ 30 → Defect.
    s.appendLine("should raise")
    expect BandNotBottomAnchoredDefect:
      discard s.commit()
    # Reset the broken commit state so the pending callSoon from scheduleCommit
    # (triggered by appendLine) finds an idle screen and returns early.
    s.setCommitInProgressForTest(false)

# ---------------------------------------------------------------------------
# Suite 3: watchResizes(InlineScreen[TerminalSink]) compile + structural
# ---------------------------------------------------------------------------

suite "S0c: watchResizes(InlineScreen[TerminalSink]) structural":

  test "watchResizes(InlineScreen[TerminalSink]) compiles and returns Future[void]":
    ## Structural compile test. We verify the overload exists and the return
    ## type is Future[void] without actually running the loop — `compiles()`
    ## evaluates at compile time, so no installResizeHandler call is needed
    ## and no SIGWINCH plumbing is touched. A runtime type assertion confirms
    ## the `typeof` is Future[void] at the call site.
    let sink = newTerminalSink(2.cint)
    let s = newInlineScreen(sink, 24, 80)
    # Verify at compile time that the overload resolves and is callable.
    check compiles(watchResizes(s))
    # Verify the return type is Future[void] via typeof (no call, no side effect).
    check (typeof(watchResizes(s)) is Future[void])

  test "watchResizes loop shape: calls setSize after SIGWINCH self-pipe byte":
    ## Integration-style structural test. Install the resize handler, spawn
    ## watchResizes(InlineScreen[TerminalSink]), send SIGWINCH to self.
    ## Allow one tick. The screen's size signal must update away from (10,20).
    ## queryWinsize falls back to (24,80) when fd 2 isn't a TTY (CI) — in
    ## that case observed[1] == (24,80). Either way, len >= 2 confirms the
    ## watcher fired and called setSize. Mirrors the TerminalScreen pattern
    ## in test_screen_v2.nim "watchResizes writes the signal when SIGWINCH fires".
    proc inner() {.async: (raises: [Exception]).} =
      let sink = newTerminalSink(2.cint)
      let s = newInlineScreen(sink, 10, 20)
      installResizeHandler()
      defer: uninstallResizeHandler()

      var observed: seq[(int, int)]
      let root = newScope()
      defer: dispose(root)
      withScope(root):
        let sizeSig {.height: 0.} = s.size
        effect [sizeSig]:
          observed.add(sizeSig)
      check observed == @[(10, 20)]

      let watcher = watchResizes(s)
      defer: watcher.cancelSoon()

      discard kill(getpid(), SIGWINCH)
      # 400 ms: matches the ceiling used in test_screen_v2.nim's equivalent
      # test; allows the SIGWINCH handler + dispatcher read callback + setSize
      # to complete even under Docker container scheduler latency.
      await sleepAsync(400.milliseconds)

      check observed.len >= 2

    waitFor inner()
