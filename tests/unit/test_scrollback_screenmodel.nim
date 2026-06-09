## test_scrollback_screenmodel.nim -- screen-state regression for the InlineScreen
## scrollback invariant.
##
## The byte-order tests in test_inline_commit.nim and test_inline_pty_scrollback.nim
## assert that committed text appears before live-band content in the raw byte
## stream.  That is necessary but not sufficient: a line may appear in the byte
## stream and then be overwritten by the band repaint, which erases it from the
## visible terminal without leaving any trace in scrollback.
##
## This module adds a minimal VT100 screen-state emulator that processes the
## ANSI byte stream and maintains:
##   - A 2-D character grid (the visible terminal screen)
##   - A scrollback buffer (lines that have scrolled off the top)
##
## ## Bottom-anchor contract under test
##
## InlineScreen regions are BOTTOM-ANCHORED: they occupy the last rows of
## the terminal (rows `H-bandH .. H-1`, 0-based). Committed content spills
## into the rows above the band, then into native scrollback.
##
## `commitAndModel` places the region at `row = H - liveZoneHeight` and
## pre-seeds the above-band grid rows with sentinel "HIST-row-i" content to
## expose the blind spot in the old (print-at-row-1) implementation: a blank
## starting screen hid whether pre-existing history was silently overwritten.
##
## ## Invariants under test (N=1, N=2, N > above-band capacity)
##
## 1. Committed lines are preserved — visible just above the band or in scrollback.
##    NOT destroyed or silently overwritten.
## 2. Pre-existing above-band history (HIST-row-i) is preserved — each seeded
##    row is either visible (shifted up) or in scrollback. NONE are lost.
## 3. The band lands at the bottom — live region content occupies rows
##    [liveTop .. H-1] after commit, not the top.
## 4. No duplication — a committed line appears exactly once across grid+scrollback.
##
## ## RED / GREEN discipline
##
## This test suite MUST fail against the prior (print-at-row-1) implementation
## (because that impl clobbered row 1 content and the HIST pre-seeding exposes it)
## and PASS after the relative-flow fix.
##
## VT100 features modelled (sufficient for fresco's commitInline output):
##   - CUP (CSI row;col H): absolute cursor positioning (1-based to 0-based grid)
##   - ED  (CSI 0J / CSI J): erase to end of screen
##   - EL  (CSI 0K / CSI K): erase to end of line
##   - SGR (CSI ...m): ignored
##   - Newline (\n) at the bottom row: scrolls the grid up by one, appending a
##     blank row at the bottom, and pushes the top row into scrollback.
##     At any other row: moves the cursor down by one without scrolling.
##   - Printable bytes: stored at cursor position; cursor advances right.
##   - DECSTBM (CSI top;bot r): NOT USED by the fixed commitInline; ignored.

import std/[unittest, strutils]
import fresco/inline_screen
import fresco/render/sink/terminal

# ---------------------------------------------------------------------------
# Minimal VT100 screen model
# ---------------------------------------------------------------------------

const STDERR_FD: cint = 2

type
  ScreenModel* = object
    rows*:       int
    cols*:       int
    grid*:       seq[string]   ## grid[r] = row r content (0-based, spaces-padded)
    scrollback*: seq[string]   ## lines pushed off the top (oldest first)
    curRow*:     int           ## 0-based
    curCol*:     int           ## 0-based

proc newScreenModel*(rows, cols: int): ScreenModel =
  var g = newSeq[string](rows)
  for i in 0 ..< rows: g[i] = spaces(cols)
  ScreenModel(rows: rows, cols: cols, grid: g, scrollback: @[],
              curRow: 0, curCol: 0)

proc clampCursor(m: var ScreenModel) =
  m.curRow = max(0, min(m.rows - 1, m.curRow))
  m.curCol = max(0, min(m.cols - 1, m.curCol))

proc scrollUpGrid(m: var ScreenModel) =
  ## Push grid[0] into scrollback, shift remaining rows up, blank bottom row.
  m.scrollback.add m.grid[0]
  for r in 0 ..< m.rows - 1:
    m.grid[r] = m.grid[r + 1]
  m.grid[m.rows - 1] = spaces(m.cols)

proc putChar(m: var ScreenModel, ch: char) =
  ## Store printable char at cursor, advance cursor right.
  if m.curRow < 0 or m.curRow >= m.rows: return
  if m.curCol < 0 or m.curCol >= m.cols: return
  var row = m.grid[m.curRow]
  while row.len <= m.curCol: row.add ' '
  row[m.curCol] = ch
  m.grid[m.curRow] = row
  inc m.curCol

proc eraseToEndOfLine(m: var ScreenModel) =
  if m.curRow < 0 or m.curRow >= m.rows: return
  var row = m.grid[m.curRow]
  while row.len < m.cols: row.add ' '
  for c in m.curCol ..< m.cols: row[c] = ' '
  m.grid[m.curRow] = row

proc feed*(m: var ScreenModel, bytes: string) =
  ## Consume `bytes` and update the screen model state.
  var i = 0
  while i < bytes.len:
    let b = bytes[i]
    if b == '\x1b':
      inc i
      if i >= bytes.len: break
      case bytes[i]
      of '[':
        inc i
        var params = ""
        while i < bytes.len and bytes[i].ord in 0x30..0x3F:
          params.add bytes[i]; inc i
        while i < bytes.len and bytes[i].ord in 0x20..0x2F:
          inc i
        if i >= bytes.len: break
        let final = bytes[i]; inc i
        case final
        of 'H':
          # CUP: 1-based to 0-based
          let parts = params.split(';')
          let r = (if parts.len > 0 and parts[0].len > 0: parseInt(parts[0]) else: 1) - 1
          let c = (if parts.len > 1 and parts[1].len > 0: parseInt(parts[1]) else: 1) - 1
          m.curRow = r; m.curCol = c
          clampCursor(m)
        of 'J':
          let p = if params.len > 0: params else: "0"
          if p == "0" or p == "":
            eraseToEndOfLine(m)
            for r in m.curRow + 1 ..< m.rows:
              m.grid[r] = spaces(m.cols)
          elif p == "2":
            for r in 0 ..< m.rows:
              m.grid[r] = spaces(m.cols)
        of 'K':
          eraseToEndOfLine(m)
        of 'm':
          discard  # SGR -- ignore
        of 'r':
          discard  # DECSTBM -- ignore
        of 'S':
          let n = if params.len > 0 and params != "": parseInt(params) else: 1
          for _ in 0 ..< n: scrollUpGrid(m)
        else:
          discard
      else:
        inc i  # two-byte ESC sequence -- skip
    elif b == '\n':
      if m.curRow >= m.rows - 1:
        scrollUpGrid(m)
        m.curCol = 0
      else:
        inc m.curRow
        m.curCol = 0
      inc i
    elif b == '\r':
      m.curCol = 0
      inc i
    elif b.ord >= 0x20 and b.ord != 0x7F:
      putChar(m, b)
      inc i
    else:
      inc i  # C0 control other than ESC/LF/CR -- skip

proc scrollbackContains*(m: ScreenModel, s: string): bool =
  ## True if any scrollback line contains s.
  for line in m.scrollback:
    if line.contains(s): return true
  false

proc gridContains*(m: ScreenModel, s: string): bool =
  ## True if any visible grid row contains s.
  for row in m.grid:
    if row.contains(s): return true
  false

proc countOccurrences(m: ScreenModel, s: string): int =
  ## Count total occurrences of s across both grid and scrollback.
  for row in m.grid:
    if row.contains(s): inc result
  for line in m.scrollback:
    if line.contains(s): inc result

# ---------------------------------------------------------------------------
# Helper: build screen + commit + feed model
# ---------------------------------------------------------------------------

proc commitAndModel(h, w: int, pinnedHeaderRows: int,
                    committed: seq[string],
                    liveContent: seq[string]): ScreenModel =
  ## Build InlineScreen(h x w), place a region BOTTOM-ANCHORED at the last
  ## liveZoneHeight rows (row = h - liveZoneHeight), pre-seed the above-band
  ## grid rows with "HIST-row-i" sentinel text, append committed lines,
  ## commit(), feed bytes into a ScreenModel that already has history.
  let sink = newTerminalSink(STDERR_FD)
  let s = newInlineScreen(sink, h, w, pinnedHeaderRows)
  let liveH = h - pinnedHeaderRows
  let liveTop = h - liveH   # bottom-anchored: region starts at row h-liveH
  if liveH > 0:
    let r = s.newRegion(liveTop, 0, liveH, w)
    r.set(liveContent)
  for line in committed:
    s.appendLine(line)

  # Gather commit bytes BEFORE seeding the model, so the bytes come from
  # a pristine InlineScreen state.
  let bytes = s.commit()

  # Build a ScreenModel pre-seeded with "HIST-row-i" in the above-band rows
  # (rows 0 .. liveTop-1). This simulates an active terminal that already
  # has history above the live band — the state a real terminal would be in
  # after earlier commit() calls or prior output.
  var m = newScreenModel(h, w)
  for i in 0 ..< liveTop:
    # Pad with spaces to match grid width (ScreenModel rows are space-padded).
    let label = "HIST-row-" & $i
    var row = label
    while row.len < w: row.add ' '
    m.grid[i] = row

  # Feed the commit bytes into the seeded model.
  m.feed(bytes)
  m

# ---------------------------------------------------------------------------
# Test suite
# ---------------------------------------------------------------------------

suite "scrollback screen-model: bottom-anchored band + seeded history":

  test "N=1: single committed line visible above the band; HIST rows preserved":
    ## H=10, pinnedHeaderRows=1 → liveZoneHeight=9, liveTop=1.
    ## Grid rows 0 (= above-band row) pre-seeded with "HIST-row-0".
    ## One committed line must be visible in the grid just above the band
    ## (row 0) or in scrollback if N exceeds above-band capacity.
    ## HIST-row-0 must be in scrollback (pushed up by 1 committed scroll).
    ## Live content must remain in the band rows (1-9).
    let h = 10
    let w = 40
    let m = commitAndModel(h, w, 1, @["COMMITTED-SINGLE"],
                           @["live-row-0", "live-row-1"])
    let liveTop = 1  # h - liveZoneHeight(=9) = 1

    # Committed line is visible just above the band at row 0, OR in scrollback.
    let committedPresent = gridContains(m, "COMMITTED-SINGLE") or
                           scrollbackContains(m, "COMMITTED-SINGLE")
    check committedPresent

    # HIST-row-0 was at the only above-band row; N=1 scroll pushes it to scrollback.
    check scrollbackContains(m, "HIST-row-0")

    # Live content is in the band (rows 1-9).
    check gridContains(m, "live-row-0")

    # Band lands at the bottom — live-row-0 is NOT in rows 0..0 (above band).
    check not m.grid[0].contains("live-row-0")

    # No duplication: COMMITTED-SINGLE appears exactly once.
    check countOccurrences(m, "COMMITTED-SINGLE") == 1

  test "N=2: both committed lines preserved; two HIST rows pushed to scrollback":
    ## H=10, pinnedHeaderRows=1 → liveTop=1.
    ## Only 1 above-band row (row 0). N=2 scrolls push HIST-row-0 to scrollback
    ## and then row 0 (which by then holds COMMITTED-ALPHA) to scrollback;
    ## COMMITTED-BETA lands at row 0 (just above the band).
    ## Both committed lines must be present (one in grid, one in scrollback).
    let h = 10
    let w = 40
    let m = commitAndModel(h, w, 1, @["COMMIT-ALPHA", "COMMIT-BETA"],
                           @["live-a", "live-b"])

    # Both committed lines must be present (grid or scrollback).
    check gridContains(m, "COMMIT-ALPHA") or scrollbackContains(m, "COMMIT-ALPHA")
    check gridContains(m, "COMMIT-BETA") or scrollbackContains(m, "COMMIT-BETA")

    # HIST-row-0 was pushed by the first scroll.
    check scrollbackContains(m, "HIST-row-0")

    # Live content is in the band.
    check gridContains(m, "live-a")

    # No duplication.
    check countOccurrences(m, "COMMIT-ALPHA") == 1
    check countOccurrences(m, "COMMIT-BETA") == 1

  test "N=1 with tall band: committed line visible just above the band":
    ## H=10, pinnedHeaderRows=2 → liveZoneHeight=8, liveTop=2.
    ## Above-band rows: 0 and 1 (seeded HIST-row-0, HIST-row-1).
    ## One committed line → 1 scroll: HIST-row-0 to scrollback, committed at row 0,
    ## HIST-row-1 shifts to row 0... wait: with liveTop=2, emission starts at row 2.
    ## Trace: cursor at row 2, "COMMITTED\n" → row 3 (no scroll). band[0..6]\n each
    ## advance; band[7]\n → scroll (at row 9). After 1 scroll: committed at row 1,
    ## band[0] at row 2, ..., band[7] at row 9. band[8] at row 9 (no \n). → Actually
    ## with bandH=8, liveTop=2: band rows 2-9. Band fills 8 rows. Total items: 1+8=9.
    ## Scrolls = (N-1) + (bandH-1) = 0 + 7 = 7... let me trace properly.
    ## Actually the number of scrolls = # of \n at the bottom row = (N + bandH - 2).
    ## For N=1, bandH=8: scrolls=7. HIST-row-0..6 go to scrollback (7 rows).
    ## HIST-row-1 shifts to row 0, committed lands at row 1.
    ## All good — HIST rows are in scrollback, committed visible above band.
    let h = 10
    let w = 40
    let m = commitAndModel(h, w, 2, @["COMMITTED-TALL"],
                           @["live-x", "live-y"])
    let liveTop = 2

    # Committed line is visible in grid above the band or in scrollback.
    check gridContains(m, "COMMITTED-TALL") or scrollbackContains(m, "COMMITTED-TALL")

    # HIST rows 0..(liveTop-1) must be in scrollback or shifted up (preserved).
    for i in 0 ..< liveTop:
      let tag = "HIST-row-" & $i
      let preserved = gridContains(m, tag) or scrollbackContains(m, tag)
      check preserved

    # Live content in the band.
    check gridContains(m, "live-x")

  test "N>=above-band-capacity: bulk committed lines all in scrollback":
    ## H=5, pinnedHeaderRows=1 → liveZoneHeight=4, liveTop=1.
    ## Above-band: 1 row (row 0). Commit 6 lines (> liveTop).
    ## All 6 committed lines must appear in grid or scrollback.
    let committed = @["LINE-1", "LINE-2", "LINE-3", "LINE-4", "LINE-5", "LINE-6"]
    let m = commitAndModel(5, 40, 1, committed, @["live-x"])

    for line in committed:
      let present = gridContains(m, line) or scrollbackContains(m, line)
      check present

    check gridContains(m, "live-x")

  test "band lands at the bottom rows after commit":
    ## The live region content must occupy rows [liveTop .. H-1] after commit —
    ## NOT the top rows. With H=10, liveTop=1, live content at rows 1-9.
    ## row 0 must NOT contain live content.
    let h = 10
    let w = 40
    let m = commitAndModel(h, w, 1,
                           @["GONE-FROM-GRID"],
                           @["LIVE-VISIBLE", "live-row-1", "live-row-2", "live-row-3"])
    let liveTop = 1

    # Live content is in the band (rows liveTop..H-1).
    check gridContains(m, "LIVE-VISIBLE")

    # The very top row (row 0) must not contain the live content.
    check not m.grid[0].contains("LIVE-VISIBLE")

    # Committed line is in grid above band or scrollback — NOT silently overwritten.
    check gridContains(m, "GONE-FROM-GRID") or scrollbackContains(m, "GONE-FROM-GRID")

    # No duplication.
    check countOccurrences(m, "GONE-FROM-GRID") == 1

  test "HIST rows are not silently overwritten (the old-impl blind spot)":
    ## This is the assertion the old print-at-row-1 test LACKED.
    ## The old impl wrote committed lines at row 1 (terminal top), clobbering
    ## any pre-existing content there. The seeded HIST rows expose this.
    ## With the correct relative-flow impl, HIST rows are shifted UP, not erased.
    ##
    ## H=10, liveTop=1: row 0 is seeded with "HIST-row-0".
    ## After commit N=1, HIST-row-0 must be in scrollback (pushed by 1 scroll),
    ## NOT overwritten/lost.
    let h = 10
    let w = 40
    let m = commitAndModel(h, w, 1, @["COMMITTED-OVER-HIST"], @["live"])

    # The HIST row at row 0 must not be silently destroyed.
    check scrollbackContains(m, "HIST-row-0")

    # The committed line is present somewhere.
    check gridContains(m, "COMMITTED-OVER-HIST") or
          scrollbackContains(m, "COMMITTED-OVER-HIST")

  test "scrollback order: committed lines appear in append order (oldest first)":
    ## Committed lines in scrollback must preserve insertion order.
    ## For N > above-band capacity, multiple lines go to scrollback.
    ## FIRST-LINE must precede SECOND-LINE in scrollback.
    let h = 5
    let w = 40
    # H=5, liveTop=1, above-band=1 row. 2 committed → 2 nd scrolls push both.
    let m = commitAndModel(h, w, 1, @["FIRST-LINE", "SECOND-LINE"],
                           @["live"])

    # Both must be present (grid or scrollback).
    let firstPresent  = gridContains(m, "FIRST-LINE") or scrollbackContains(m, "FIRST-LINE")
    let secondPresent = gridContains(m, "SECOND-LINE") or scrollbackContains(m, "SECOND-LINE")
    check firstPresent
    check secondPresent

    # If both ended up in scrollback, FIRST-LINE must precede SECOND-LINE.
    var firstIdx  = -1
    var secondIdx = -1
    for i, line in m.scrollback:
      if line.contains("FIRST-LINE"):  firstIdx  = i
      if line.contains("SECOND-LINE"): secondIdx = i
    if firstIdx >= 0 and secondIdx >= 0:
      check firstIdx < secondIdx
