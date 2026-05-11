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
    height*, width*: int
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
    if r.known[absRow] and r.current[absRow] == line:
      continue
    result &= cursorTo(absRow + 1, col + 1)
    result &= clearLineRight()
    result &= line
    r.current[absRow] = line
    r.known[absRow] = true
