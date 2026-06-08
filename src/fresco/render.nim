## Smart line-update renderer.
##
## A `Renderer` holds a per-row snapshot of what the terminal currently
## shows. `render(row, col, target)` returns the ANSI bytes needed to
## bring rows [row..row+target.len) to match `target`; if a target row
## is already current, that row contributes zero bytes. Cursor moves
## are only emitted for rows that actually change.
##
## v0 contract: regions do not overlap horizontally on the same row.
## Each row is owned by at most one writer, so per-row caching is
## sufficient. Character-level diffing is a later optimization.

import ./terminal/ansi

type
  Renderer* = ref object
    height, width: int   ## internal — callers reach through Screen
    current: seq[string]
    known:   seq[bool]

proc newRenderer*(height, width: int): Renderer =
  Renderer(
    height: height, width: width,
    current: newSeq[string](height),
    known:   newSeq[bool](height),
  )

proc invalidate*(r: Renderer) =
  ## Drop the cached snapshot. Next render emits every row even if its
  ## content matches what we last sent. Use on SIGWINCH / alt-screen
  ## entry / any time the terminal may have been clobbered externally.
  for i in 0 ..< r.known.len:
    r.known[i] = false
    r.current[i] = ""

proc resize*(r: Renderer, height, width: int) =
  r.height = height
  r.width = width
  r.current = newSeq[string](height)
  r.known   = newSeq[bool](height)

proc render*(r: Renderer, row, col: int,
             target: openArray[string]): string =
  ## Diff `target` against the cached snapshot and emit only the rows
  ## that changed. `row`/`col` are 0-based; ANSI CUP is 1-based and the
  ## conversion happens here.
  result = ""
  for i, line in target:
    let absRow = row + i
    if absRow < 0 or absRow >= r.height: continue
    when compileOption("assertions"):
      doAssert displayWidth(line) <= r.width,
        "render: line display width " & $displayWidth(line) &
        " exceeds renderer width " & $r.width &
        " at row " & $absRow & " col " & $col
    if r.known[absRow] and r.current[absRow] == line:
      continue
    result &= cursorTo(absRow + 1, col + 1)
    result &= clearLineRight()
    result &= line
    r.current[absRow] = line
    r.known[absRow] = true

proc scrollUpRegion*(r: Renderer, topRow, botRow, n: int): string =
  ## Emit ANSI to scroll the contents of rows [topRow, botRow]
  ## up by `n` lines using DECSTBM. After the emission, rows
  ## `[topRow, botRow-n]` show what was in `[topRow+n, botRow]`;
  ## rows `[botRow-n+1, botRow]` are now blank (the terminal cleared
  ## them as it scrolled them in).
  ##
  ## Updates the Renderer's cached snapshot to match the terminal's
  ## post-scroll state — so callers can immediately follow up with
  ## `render(...)` to paint only the newly-revealed bottom rows,
  ## without spurious diffs on the now-shifted rows above.
  ##
  ## Rows are 0-based; ANSI CUP/DECSTBM are 1-based and the
  ## conversion happens here. No-op for `n <= 0` or zero-height ranges.
  if n <= 0 or topRow > botRow: return ""
  if topRow < 0 or botRow >= r.height: return ""
  let shiftN = min(n, botRow - topRow + 1)
  # `CSI n S` (scrollUp) operates on the scroll region's contents
  # regardless of current cursor position — no CUP needed here. The
  # subsequent `render(...)` for changed rows emits its own CUP
  # explicitly, so cursor placement is well-defined after the scroll.
  result = setScrollRegion(topRow + 1, botRow + 1) &
           scrollUp(shiftN) &
           resetScrollRegion()
  # Update the cache to mirror the new terminal contents:
  # row[topRow + i] now holds what was at row[topRow + i + shiftN]
  # for i in 0 .. botRow-topRow-shiftN. Bottom shiftN rows become "".
  for i in topRow .. botRow - shiftN:
    r.current[i] = r.current[i + shiftN]
    r.known[i]   = r.known[i + shiftN]
  for i in botRow - shiftN + 1 .. botRow:
    r.current[i] = ""
    r.known[i] = true       # terminal cleared, so cache reflects that
