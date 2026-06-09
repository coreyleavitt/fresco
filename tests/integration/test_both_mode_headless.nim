## test_both_mode_headless.nim — S4 Slice 13: headless both-mode end-to-end.
##
## Suite A — AltScreen end-to-end (screen-owning):
##   A1. Final live state via MemorySink: enter, paint, assert sink.rows.
##       Mutate + repaint, assert update landed.
##   A2. Restore bytes via TerminalSink.flush: assert enter emits ?1049h
##       before content, leave emits ?1049l after content.
##
## Suite B — InlineScreen end-to-end (inline, bottom-anchored):
##   B1. Live-band content only via MemorySink: appendLine + commit.
##       Assert live-band region content in sink.rows; committed lines
##       ABSENT from sink.rows; log drained to 0.
##   B2. No stale cells: resize region content to shorter line after first
##       paint; repaint/commit; assert vacated cells are blank.

import std/[posix, strutils, unittest]
import fresco/altscreen
import fresco/inline_screen
import fresco/render/layout
import fresco/render/sink/memory
import fresco/render/sink/terminal
import fresco/terminal/altscreen_cap
import fresco/terminal/ansi

# ---------------------------------------------------------------------------
# Shared: minimal AltScreen cap witness (same pattern as test_altscreen.nim)
# ---------------------------------------------------------------------------

type AltCapWitness = object
  altScreenGrant: AltScreenGrant

# ---------------------------------------------------------------------------
# Pipe helpers for byte-capture (mirrored from test_altscreen.nim)
# ---------------------------------------------------------------------------

proc readAvailable(fd: cint): string =
  var buf: array[4096, char]
  result = ""
  while true:
    let n = posix.read(fd, addr buf[0], buf.len)
    if n <= 0: break
    for i in 0 ..< n:
      result.add buf[i]
    if n < buf.len: break

proc setNonblock(fd: cint) =
  let flags = fcntl(fd, F_GETFL, 0)
  discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)

# ---------------------------------------------------------------------------
# Suite A: AltScreen end-to-end
# ---------------------------------------------------------------------------

suite "S4 slice 13 Suite A: AltScreen headless end-to-end":

  test "A1a: enter + paint — sink.rows reflects live region content":
    ## MemorySink captures the final live state. AltScreen owns the full
    ## screen — every row is assertable.
    let sink = newMemorySink()
    let s = newAltScreen(sink, 4, 20, AltCapWitness())

    let r = newRegion(s.layout, 0, 0, 3, 20)
    r.set(@["row-alpha", "row-beta", "row-gamma"])

    s.enter()
    s.paint()

    # Three content rows + one uncovered row (row 3).
    check sink.rows.len == 4
    check sink.rows[0] == "row-alpha"
    check sink.rows[1] == "row-beta"
    check sink.rows[2] == "row-gamma"
    check sink.rows[3] == ""   # uncovered → blank

  test "A1b: mutate content + repaint — sink.rows reflects the update":
    let sink = newMemorySink()
    let s = newAltScreen(sink, 3, 20, AltCapWitness())

    let r = newRegion(s.layout, 0, 0, 3, 20)
    r.set(@["first", "second", "third"])

    s.enter()
    s.paint()

    check sink.rows[0] == "first"

    # Mutate and repaint.
    r.set(@["updated-0", "updated-1", "updated-2"])
    s.paint()

    check sink.rows[0] == "updated-0"
    check sink.rows[1] == "updated-1"
    check sink.rows[2] == "updated-2"

  test "A2: enter emits ?1049h before content; leave emits ?1049l after content":
    ## TerminalSink over a pipe — assert lifecycle bytes.
    var pipefds: array[2, cint]
    doAssert pipe(pipefds) == 0
    let rd = pipefds[0]; let wr = pipefds[1]
    setNonblock(rd)
    defer:
      discard close(rd)
      discard close(wr)

    let sink = newTerminalSink(wr)
    let s = newAltScreen(sink, 2, 20, AltCapWitness())

    let r = newRegion(s.layout, 0, 0, 2, 20)
    r.set(@["hello", "world"])

    s.enter()
    s.paint()

    let bytesBeforeLeave = readAvailable(rd)

    # ?1049h present and precedes content.
    check altScreenEnter() in bytesBeforeLeave
    check "hello" in bytesBeforeLeave
    let enterPos  = bytesBeforeLeave.find(altScreenEnter())
    let helloPos  = bytesBeforeLeave.find("hello")
    check enterPos >= 0
    check helloPos > enterPos

    s.leave()
    let bytesAfterLeave = bytesBeforeLeave & readAvailable(rd)

    # ?1049l present and follows content.
    check altScreenLeave() in bytesAfterLeave
    let leavePos  = bytesAfterLeave.find(altScreenLeave())
    let alphaPos2 = bytesAfterLeave.find("hello")
    check alphaPos2 < leavePos

# ---------------------------------------------------------------------------
# Suite B: InlineScreen end-to-end
# ---------------------------------------------------------------------------

suite "S4 slice 13 Suite B: InlineScreen headless end-to-end":

  test "B1a: live-band region content present in sink.rows after commit":
    ## h=5, w=20, pinnedHeaderRows=1 → liveZoneHeight=4.
    ## Bottom-anchored: region at row 1 (h - liveZoneHeight = 5 - 4 = 1).
    let sink = newMemorySink()
    let s = newInlineScreen(sink, 5, 20, pinnedHeaderRows = 1)

    let r = s.newRegion(1, 0, 4, 20)
    r.set(@["live-a", "live-b", "live-c", "live-d"])

    appendLine(s, "committed-1")
    appendLine(s, "committed-2")

    discard commit(s)

    # Live-band region rows (rows 1–4) must carry the region content.
    check sink.rows.len == 5
    check sink.rows[1] == "live-a"
    check sink.rows[2] == "live-b"
    check sink.rows[3] == "live-c"
    check sink.rows[4] == "live-d"

  test "B1b: committed lines ABSENT from sink.rows (MemorySink has no scrollback)":
    ## MemorySink models no scrollback; committed history is invisible.
    ## Bottom-anchored: region at row 1 (h - liveZoneHeight = 5 - 4 = 1).
    let sink = newMemorySink()
    let s = newInlineScreen(sink, 5, 20, pinnedHeaderRows = 1)

    let r = s.newRegion(1, 0, 4, 20)
    r.set(@["live-a", "live-b", "live-c", "live-d"])

    appendLine(s, "committed-1")
    appendLine(s, "committed-2")

    discard commit(s)

    # Neither committed line may appear in any row of sink.rows.
    for row in sink.rows:
      check "committed-1" notin row
      check "committed-2" notin row

  test "B1c: log drains to 0 after commit":
    ## Bottom-anchored: region at row 1 (h - liveZoneHeight = 5 - 4 = 1).
    let sink = newMemorySink()
    let s = newInlineScreen(sink, 5, 20, pinnedHeaderRows = 1)

    let r = s.newRegion(1, 0, 4, 20)
    r.set(@["live-a", "live-b"])

    appendLine(s, "committed-1")
    appendLine(s, "committed-2")

    check s.logPendingLen() == 2
    discard commit(s)
    check s.logPendingLen() == 0

  test "B2: no stale cells — vacated row blank-filled after content shrink":
    ## Paint wide content, then shrink to a shorter line + repaint.
    ## The previously-occupied cells must be blank (not stale old content).
    let sink = newMemorySink()
    let s = newInlineScreen(sink, 5, 20, pinnedHeaderRows = 1)

    # Single live-band region, 2 rows × 20 cols.
    let r = s.newRegion(0, 0, 2, 20)
    r.set(@["long-first-row", "long-second-row"])
    s.paint()

    # Verify both rows have content after the first paint.
    check "long-first-row" in sink.rows[0]
    check "long-second-row" in sink.rows[1]

    # Shrink: one short row only — second row vacated entirely.
    r.set(@["short"])
    s.paint()

    # First row holds the new content.
    check "short" in sink.rows[0]
    # Second row must be blank — no stale "long-second-row" left over.
    check "long-second-row" notin sink.rows[1]
    check sink.rows[1] == ""
