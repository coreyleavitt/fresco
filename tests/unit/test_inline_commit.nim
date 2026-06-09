## test_inline_commit.nim — Slice 10+10b: inline commit pipeline
## (native-scroll + cache invalidate + cursor-home) over byte-capture seam.
##
## Five test cases:
##   1. Byte-order (core round-3 assertion): pre-drain→cursorTo(liveTop)→
##      committed prints→live-band repaint→cursorTo(input)
##   2. Pure-SGR committed line (zero display width) advances exactly one row.
##   3. Cursor-home (10b): final cursorTo targets (inputRow+1, inputCol+1).
##   4. Drain empties the log; commitInProgress cleared.
##   5. Zero-height clamp preserves pending; returns empty bytes.

{.experimental: "callOperator".}

import std/[unittest, strutils]
import fresco/inline_screen
import fresco/terminal/ansi
import fresco/render/sink/terminal

# Use STDERR_FILENO (fd 2) as the sink fd. The test asserts on the
# *return value* of commit() (the byte string), not on what gets written
# to the fd, so writing to stderr is acceptable here.
const STDERR_FD: cint = 2

proc makeScreen(h, w: int, pinnedHeaderRows = 1): (InlineScreen[TerminalSink], TerminalSink) =
  let sink = newTerminalSink(STDERR_FD)
  let s = newInlineScreen(sink, h, w, pinnedHeaderRows)
  (s, sink)

suite "InlineScreen slice 10+10b: inline commit pipeline":

  test "byte-order: cursorTo(liveTop) → committed lines → live repaint → cursorTo(input)":
    # Build a 10-row, 40-col screen with pinnedHeaderRows=1 → liveZoneHeight=9.
    # liveTop = row 0 of layout (the only region).
    # Set inputRow=5, inputCol=3 so the final cursorTo is distinct.
    let (s, _) = makeScreen(10, 40)
    let r = s.newRegion(0, 0, 9, 40)
    r.set(["live line one", "live line two"])

    let ls = s.logSink
    ls.append("committed one")
    ls.append("committed two")

    s.inputRow = 5
    s.inputCol = 3

    let bytes = commit(s)

    # Determine liveTop = min r.row = 0 → cursorTo(1, 1)
    let liveTopCursor = cursorTo(1, 1)
    let committedOne  = "committed one\n"
    let committedTwo  = "committed two\n"
    let inputCursor   = cursorTo(6, 4)  # inputRow+1=6, inputCol+1=4

    let posLiveTop   = bytes.find(liveTopCursor)
    let posCommit1   = bytes.find(committedOne)
    let posCommit2   = bytes.find(committedTwo)
    # The live-band repaint emits a cursorTo for the region's row (row 0 → row+1=1).
    # After invalidation + repaint, the renderer emits cursorTo(1,1) for row 0.
    # Look for the region's live content instead — the actual rendered line.
    # The repaint re-emits cursorTo(r.row+1, r.col+1) = cursorTo(1,1) for row 0,
    # but that's the same as liveTopCursor; use the live content string as anchor.
    let liveContent  = bytes.find("live line one")
    let posInput     = bytes.rfind(inputCursor)  # last occurrence = final position

    check posLiveTop  >= 0
    check posCommit1  >= 0
    check posCommit2  >= 0
    check liveContent >= 0
    check posInput    >= 0

    # Strict ordering
    check posLiveTop  < posCommit1
    check posCommit1  < posCommit2
    check posCommit2  < liveContent
    check liveContent < posInput

  test "pure-SGR committed line (zero display width) appears verbatim + newline":
    let (s, _) = makeScreen(5, 40)
    let r = s.newRegion(0, 0, 4, 40)
    r.set(["live"])

    let puresgr = "\x1b[31m\x1b[0m"
    s.logSink.append(puresgr)
    let bytes = commit(s)

    check bytes.find(puresgr & "\n") >= 0
    check physicalRows(puresgr, 40) == 1

  test "cursor-home (10b): final cursorTo in bytes targets (inputRow+1, inputCol+1)":
    let (s, _) = makeScreen(8, 40)
    let r = s.newRegion(0, 0, 7, 40)
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
    let r = s.newRegion(0, 0, 4, 40)
    r.set(["live"])
    s.logSink.append("line a")
    s.logSink.append("line b")
    s.logSink.append("line c")
    check s.logPendingLen() == 3
    discard commit(s)
    check s.logPendingLen() == 0
    check s.commitInProgress == false

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
    let r = s.newRegion(0, 0, 4, 40)
    r.set(["live"])
    appendLine(s, "hi")
    let bytes1 = commit(s)
    check bytes1.find("hi\n") >= 0
    check s.logPendingLen() == 0
    let bytes2 = commit(s)
    # Second commit with empty log must not re-emit "hi".
    check bytes2.find("hi\n") < 0
