## test_inline_commit.nim — Slice 10+10b: inline commit pipeline
## (relative-flow native-scroll + cache invalidate + cursor-home) over
## the byte-capture seam.
##
## Five test cases:
##   1. Byte-order (core assertion): cursorTo(liveTop+1,1) → ED0 →
##      committed lines → live band rows (as \n flow) → cursorTo(input).
##   2. Pure-SGR committed line (zero display width) emitted verbatim + \n.
##   3. Cursor-home (10b): final cursorTo targets (inputRow+1, inputCol+1).
##   4. Drain empties the log; commitInProgress cleared.
##   5. Zero-height clamp preserves pending; returns empty bytes.

{.experimental: "callOperator".}

import std/[unittest, strutils]
import fresco/inline_screen
import fresco/terminal/ansi
import fresco/render/sink/terminal
import fresco/render/sink/memory

# Use STDERR_FILENO (fd 2) as the sink fd. The test asserts on the
# *return value* of commit() (the byte string), not on what gets written
# to the fd, so writing to stderr is acceptable here.
const STDERR_FD: cint = 2

proc makeScreen(h, w: int, pinnedHeaderRows = 1): (InlineScreen[TerminalSink], TerminalSink) =
  let sink = newTerminalSink(STDERR_FD)
  let s = newInlineScreen(sink, h, w, pinnedHeaderRows)
  (s, sink)

suite "InlineScreen slice 10+10b: inline commit pipeline":

  test "byte-order: cursorTo(liveTop+1,1) → ED0 → committed lines → live rows → cursorTo(input)":
    ## Build a 10-row, 40-col screen with pinnedHeaderRows=1 → liveZoneHeight=9.
    ## Regions are bottom-anchored: row H-liveZoneHeight = 10-9 = 1 (0-based).
    ## liveTop = region.row = 1 (0-based), so cursorTo(liveTop+1, 1) = cursorTo(2, 1).
    ## Set inputRow=5, inputCol=3 so the final cursorTo is distinct.
    ##
    ## Expected emit sequence (new relative-flow algorithm):
    ##   cursorTo(2, 1)         — top of the band (liveTop+1, 1-based)
    ##   "\x1b[0J"              — ED 0: erase to end of screen
    ##   "committed one\n"      — committed line 1 (raw)
    ##   "committed two\n"      — committed line 2 (raw)
    ##   "live line one\n"      — band row 0 (clipped, \n flow)
    ##   "live line two\n"      — band row 1 (clipped, \n flow) etc.
    ##   cursorTo(6, 4)         — input home (inputRow+1=6, inputCol+1=4)
    let h = 10
    let w = 40
    let (s, _) = makeScreen(h, w)
    # Bottom-anchored region: liveZoneHeight=9 rows starting at row 1 (0-based).
    let liveZH = 9
    let liveTop = h - liveZH  # = 1
    let r = s.newRegion(liveTop, 0, liveZH, w)
    r.set(["live line one", "live line two"])

    let ls = s.logSink
    ls.append("committed one")
    ls.append("committed two")

    s.inputRow = 5
    s.inputCol = 3

    let bytes = commit(s)

    let bandTopCursor = cursorTo(liveTop + 1, 1)  # cursorTo(2, 1)
    let eraseToEnd    = "\x1b[0J"
    let committedOne  = "committed one\n"
    let committedTwo  = "committed two\n"
    let liveContent   = "live line one"
    let inputCursor   = cursorTo(6, 4)  # inputRow+1=6, inputCol+1=4

    let posBandTop   = bytes.find(bandTopCursor)
    let posErase     = bytes.find(eraseToEnd)
    let posCommit1   = bytes.find(committedOne)
    let posCommit2   = bytes.find(committedTwo)
    let posLive      = bytes.find(liveContent)
    let posInput     = bytes.rfind(inputCursor)

    check posBandTop  >= 0
    check posErase    >= 0
    check posCommit1  >= 0
    check posCommit2  >= 0
    check posLive     >= 0
    check posInput    >= 0

    # Strict ordering: band-top → erase → committed lines → live rows → input home
    check posBandTop  < posErase
    check posErase    < posCommit1
    check posCommit1  < posCommit2
    check posCommit2  < posLive
    check posLive     < posInput

    # The old "go to row 1" clobber-top cursor must NOT appear before committed lines
    # (would mean we are printing at top of terminal rather than at liveTop).
    # cursorTo(1,1) may appear only as part of pendingScroll pre-drain or not at all;
    # it must never be the very first CUP and then be followed immediately by committed text.
    # Simplest: check that cursorTo(1,1) does NOT appear before the eraseToEnd.
    let posTop1 = bytes.find(cursorTo(1, 1))
    check posTop1 < 0 or posTop1 > posErase

  test "pure-SGR committed line (zero display width) appears verbatim + newline":
    let (s, _) = makeScreen(5, 40)
    # Bottom-anchored: h=5, pinnedHeaderRows=1, liveZoneHeight=4 → region at row 1.
    let r = s.newRegion(1, 0, 4, 40)
    r.set(["live"])

    let puresgr = "\x1b[31m\x1b[0m"
    s.logSink.append(puresgr)
    let bytes = commit(s)

    check bytes.find(puresgr & "\n") >= 0
    check physicalRows(puresgr, 40) == 1

  test "cursor-home (10b): final cursorTo in bytes targets (inputRow+1, inputCol+1)":
    let h = 8
    let w = 40
    let (s, _) = makeScreen(h, w)
    # Bottom-anchored: liveZoneHeight=7, region at row h-7=1.
    let r = s.newRegion(1, 0, 7, w)
    r.set(["content"])
    s.logSink.append("a line")
    s.inputRow = 3
    s.inputCol = 7
    let bytes = commit(s)
    let expected = cursorTo(4, 8)  # inputRow+1=4, inputCol+1=8
    # The final cursor-home must be the last cursorTo in the stream.
    check bytes.rfind(expected) >= 0
    # And nothing that looks like another cursorTo comes after it.
    let pos = bytes.rfind(expected)
    # After the expected cursor, nothing else is a CUP escape.
    let tail = bytes[pos + expected.len .. ^1]
    check tail.find("\x1b[") < 0 or tail.find("H") < 0

  test "drain empties the log; commitInProgress cleared after commit":
    let (s, _) = makeScreen(5, 40)
    # Bottom-anchored: h=5, pinnedHeaderRows=1, liveZoneHeight=4 → region at row 1.
    let r = s.newRegion(1, 0, 4, 40)
    r.set(["live"])
    s.logSink.append("line a")
    s.logSink.append("line b")
    s.logSink.append("line c")
    check s.logPendingLen() == 3
    discard commit(s)
    check s.logPendingLen() == 0
    check s.isCommitInProgress() == false

  test "zero-height clamp: liveZoneHeight=0 preserves pending and returns empty bytes":
    # h=1, pinnedHeaderRows=1 → liveZoneHeight = max(0, 1-1) = 0
    let (s, _) = makeScreen(1, 40, pinnedHeaderRows = 1)
    s.logSink.append("should be preserved")
    let bytes = commit(s)
    check bytes == ""
    check s.logPendingLen() == 1

suite "InlineScreen slice 11 A3: appendLine":

  test "appendLine with embedded newline stores single sanitized line":
    # appendLine routes through append → sanitize; embedded \n yields "xy" not two lines.
    let (s, _) = makeScreen(5, 40)
    let r = s.newRegion(0, 0, 4, 40)
    r.set(["live"])
    appendLine(s, "x\ny")
    check s.logPendingLen() == 1
    let batch = s.logDrainBatch(1)
    check batch == @["xy"]

  test "appendLine commit + idempotency: second commit does not re-emit the line":
    # After commit drains the line, a second commit with no new appends emits nothing.
    let (s, _) = makeScreen(5, 40)
    # Bottom-anchored: h=5, pinnedHeaderRows=1, liveZoneHeight=4 → region at row 1.
    let r = s.newRegion(1, 0, 4, 40)
    r.set(["live"])
    appendLine(s, "hi")
    let bytes1 = commit(s)
    check bytes1.find("hi\n") >= 0
    check s.logPendingLen() == 0
    let bytes2 = commit(s)
    # Second commit with empty log must not re-emit "hi".
    check bytes2.find("hi\n") < 0

suite "InlineScreen M9c: sync commit re-entrancy determinism":

  test "commit with isCommitInProgress already true via seam behaves deterministically":
    ## Documents the sync commit path's behavior when commitInProgress is
    ## forcibly set to true via the test seam before the call. The sync
    ## commit proc sets commitInProgress = true at its start, so it is
    ## idempotent with respect to the flag's initial value. The line is
    ## still drained and logPendingLen becomes 0, because the sync path's
    ## batch loop does not gate on isCommitInProgress — it gates on
    ## logPendingLen and liveZoneHeight only.
    ##
    ## This test exists purely as a seam-exercise / behavior doc. It is NOT
    ## testing a guard that blocks the call; it is asserting the drain still
    ## completes so the behavior is specified rather than implicit.
    let s = newInlineScreen(newMemorySink(), 5, 20)
    # Bottom-anchored: h=5, pinnedHeaderRows=1, liveZoneHeight=4 → region at row 1.
    let r = s.newRegion(1, 0, 4, 20)
    r.set(["live"])
    s.logSink.append("reentrant-line")
    s.setCommitInProgressForTest(true)
    discard s.commit()
    check s.logPendingLen() == 0
    check s.isCommitInProgress() == false

# --- Design-2: bottom-anchor enforcement ---

suite "InlineScreen Design-2: bottom-anchor enforcement":

  test "Design-2: region NOT reaching terminal bottom raises on commit with pending lines":
    ## Place a region at the TOP of the screen (not reaching the bottom).
    ## With committed lines to drain, commit must raise ValueError naming the
    ## violated contract.
    let s = newInlineScreen(newMemorySink(), 10, 40)
    # h=10; place region at row 0, height 4 → edge=4, but height=10. NOT bottom-anchored.
    let r = s.newRegion(0, 0, 4, 40)
    r.set(["live"])
    s.logSink.append("must raise")

    var raised = false
    var msg = ""
    try:
      discard s.commit()
    except BandNotBottomAnchoredDefect as e:
      raised = true
      msg = e.msg

    check raised
    check msg.contains("bottom-anchored")

  test "Design-2: bottom-anchored region does NOT raise on commit with pending lines":
    ## Place region correctly: row = h - liveZoneHeight (bottom-anchored).
    ## commit must succeed without raising.
    let s = newInlineScreen(newMemorySink(), 10, 40)
    # h=10, pinnedHeaderRows=1, liveZoneHeight=9 → region at row 1, height 9 → edge=10=h.
    let r = s.newRegion(1, 0, 9, 40)
    r.set(["live"])
    s.logSink.append("should not raise")

    var raised = false
    try:
      discard s.commit()
    except BandNotBottomAnchoredDefect:
      raised = true

    check not raised
    check s.logPendingLen() == 0

  test "Design-2: no regions — commit with pending lines does NOT raise (no anchor check)":
    ## Without any regions the invariant is vacuously satisfied — no check fires.
    let s = newInlineScreen(newMemorySink(), 10, 40)
    s.logSink.append("no-region-line")

    var raised = false
    try:
      discard s.commit()
    except BandNotBottomAnchoredDefect:
      raised = true

    check not raised
