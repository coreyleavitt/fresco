## Layout — the multi-region spatial coordinator.
##
## Layout extracts the *structural* concerns from the older Screen
## type: dimensions, region allocation, region collection. It does
## not know how to emit. That's what `Sink`s do.
##
## Region is the per-area state — its `target: seq[string]` is the
## current content, `pending: bool` flags dirty, `pendingScroll: int`
## requests a scroll-region operation from the sink.
##
## ## Why this exists
##
## The pre-split `Screen` bundled spatial coordination with ANSI
## emission. The headless / web / file / sidecar use cases all want
## the coordination *without* the emission. Splitting Screen into
## `Layout` (this file) + `Sink` (a concept) lets every frontend
## pick its own emission strategy while sharing the spatial model.

import ../terminal/ansi

type
  Region* = ref object
    row*, col*, height*, width*: int
    target: seq[string]
    pending*: bool
    pendingScroll*: int
      ## When non-zero, the sink should perform a DECSTBM-style scroll
      ## of `pendingScroll` lines over the region's rows BEFORE the
      ## standard target diff. Used by `bindCollection`'s wmFromEnd
      ## fast-path to avoid repainting every visible row on a tail
      ## append; the terminal scrolls, then only the new bottom row
      ## paints. Sinks that don't support scroll (MemorySink in v0,
      ## anything stateless) ignore this and rely on the slow-path
      ## repaint that follows.

  Layout* = ref object
    height*, width*: int
    regions*: seq[Region]

proc newLayout*(height, width: int): Layout =
  Layout(height: height, width: width, regions: @[])

proc newRegion*(l: Layout, row, col, height, width: int): Region =
  if row < 0 or col < 0 or height <= 0 or width <= 0 or
     row + height > l.height or col + width > l.width:
    raise newException(ValueError,
      "region (" & $row & "," & $col & "," & $height & "x" & $width &
      ") out of layout bounds " & $l.height & "x" & $l.width)
  result = Region(row: row, col: col, height: height, width: width)
  l.regions.add result

proc set*(r: Region, content: openArray[string]) =
  ## Queue a new target. The next sink commit will emit only the
  ## differences from the prior commit. Overflowing rows
  ## (content longer than `r.height`) are truncated. Each row is
  ## clipped to `r.width` display columns via `clipToWidth`.
  ##
  ## `target` is always sized to `r.height`. Rows from `content.len`
  ## through `r.height-1` are explicitly blanked ("") so that old
  ## content from a previous larger `set` does not linger (the
  ## stale-on-shrink fix).
  let srcLen = min(content.len, r.height)
  if r.target.len != r.height:
    r.target.setLen(r.height)
  for i in 0 ..< srcLen:
    let clipped = clipToWidth(content[i], r.width)
    if r.target[i] != clipped:
      r.target[i] = clipped
  for i in srcLen ..< r.height:
    if r.target[i] != "":
      r.target[i] = ""
  r.pending = true

proc markDirty*(r: Region) =
  ## Force `r` to be re-emitted on the next commit even if its target
  ## hasn't changed (e.g. after the renderer was invalidated externally).
  r.pending = true

proc setRow*(r: Region, idx: int, line: string) =
  ## Replace a single row in the region's target. Idx is region-local
  ## (0 == top of region). Out-of-bounds is silently dropped.
  ## The row is clipped to `r.width` display columns via `clipToWidth`.
  if idx < 0 or idx >= r.height: return
  while r.target.len <= idx: r.target.add ""
  let clipped = clipToWidth(line, r.width)
  if r.target[idx] != clipped:
    r.target[idx] = clipped
    r.pending = true

proc setRowChecked*(r: Region, idx: int, line: string) {.inline.} =
  ## Store a pre-clipped row directly, bypassing `clipToWidth`. For
  ## callers that have already called `clipToWidth` (e.g. the DECSTBM
  ## fast-path) so the chokepoint doesn't re-clip in a hot loop.
  ## Under assertions, a doAssert guards that `line` is truly within
  ## width. Exported as an internal-perf API.
  when compileOption("assertions"):
    doAssert displayWidth(line) <= r.width,
      "setRowChecked: line display width " & $displayWidth(line) &
      " exceeds region width " & $r.width
  if idx < 0 or idx >= r.height: return
  while r.target.len <= idx: r.target.add ""
  if r.target[idx] != line:
    r.target[idx] = line
    r.pending = true

proc scrollUp*(r: Region, n: int) =
  ## Queue a scroll-up of `n` lines within the region's rows. The
  ## next sink commit interprets `pendingScroll` per its own
  ## semantics (TerminalSink emits DECSTBM; MemorySink shifts the
  ## captured buffer or falls back to repaint).
  ## Zero-height guard: if the region has zero height, skip — a
  ## wmFromEnd delta during a zero-height window must not leave a
  ## stale pendingScroll that fires wrongly on grow-back.
  if r.height == 0: return
  r.pendingScroll = n

proc rows*(r: Region): lent seq[string] =
  ## Read accessor for the region's current target rows. Zero-copy
  ## (lent return). Callers use r.rows[i] / r.rows.len / r.rows ==
  ## seq comparisons. The underlying field (`target`) is private;
  ## all writes go through `set`/`setRow`/`setRowChecked`.
  r.target

proc resizeRows*(r: Region, n: int) =
  ## Truncate `target` to at most `n` rows. Matches the inline
  ## `if r.target.len > r.height: r.target.setLen(r.height)` idiom
  ## used in screen.nim's setSize. Grows are not needed here (the
  ## set/setRow procs handle that); this is truncation-only.
  if r.target.len > n:
    r.target.setLen(n)

proc reclipRows*(r: Region) =
  ## Re-clip every cached row in `r.target` to `r.width` display columns.
  ##
  ## Call this AFTER updating `r.width` (e.g. on a width-shrink resize) so
  ## cached rows wider than the new width don't bleed horizontally or trip
  ## the `doAssert displayWidth(line) <= r.width` guard in `setRowChecked`.
  ##
  ## `r.rows` returns a `lent seq[string]` which Nim copies into `cur` here,
  ## so iterating `cur` while mutating `r.target` via `setRow` is safe.
  let cur = r.rows
  for i in 0 ..< cur.len:
    r.setRow(i, cur[i])

proc anyPending*(l: Layout): bool =
  ## True iff any region in `l` has unpainted content (`pending`) or a
  ## queued scroll operation (`pendingScroll`). The canonical "does this
  ## layout owe a paint" scan — the Screen and InlineScreen auto-paint
  ## gates share this one definition rather than each keeping its own
  ## private copy.
  for r in l.regions:
    if r.pending or r.pendingScroll != 0: return true
  false

proc reanchorBottom*(layout: Layout, bandRegions: openArray[Region]) =
  ## Restack a set of bottom-anchored band regions so the band's lowest
  ## edge reaches `layout.height` after a terminal resize.
  ##
  ## `bandRegions` must be in top-to-bottom order. Each region's `row` is
  ## recomputed so they stack contiguously and the lowest region's bottom
  ## edge equals `layout.height` (satisfying the bottom-anchor contract
  ## `max(r.row + r.height) == H`). Heights are NOT changed — only `row`
  ## fields are updated.
  ##
  ## Degenerate cases:
  ##   - Zero regions → no-op.
  ##   - Sum of heights > layout.height → `startRow` clamps to 0; each
  ##     region's `row` is assigned sequentially from 0, which may produce
  ##     rows that overflow `layout.height`. This mirrors the zero-height
  ##     clamp convention in `applySizeNow`: the caller should call
  ##     `applySizeNow` (via `setSize`) BEFORE `reanchorBottom` so oversized
  ##     regions have already been height-clamped.
  ##   - A region with height == 0 contributes 0 rows but its `row` is still
  ##     assigned (it occupies no vertical space).
  ##
  ## After this call, the next `commit` will NOT raise `BandNotBottomAnchoredDefect`
  ## provided the sum of heights fits within `layout.height`.
  if bandRegions.len == 0:
    return
  var totalH = 0
  for r in bandRegions:
    totalH += r.height
  var row = max(0, layout.height - totalH)
  for r in bandRegions:
    r.row = row
    row += r.height
