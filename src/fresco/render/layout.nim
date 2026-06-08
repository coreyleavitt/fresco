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

type
  Region* = ref object
    row*, col*, height*, width*: int
    target*: seq[string]
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
  ## (content longer than `r.height`) are truncated.
  if content.len <= r.height:
    r.target = @content
  else:
    r.target = @(content[0 ..< r.height])
  r.pending = true

proc markDirty*(r: Region) =
  ## Force `r` to be re-emitted on the next commit even if its target
  ## hasn't changed (e.g. after the renderer was invalidated externally).
  r.pending = true

proc setRow*(r: Region, idx: int, line: string) =
  ## Replace a single row in the region's target. Idx is region-local
  ## (0 == top of region). Out-of-bounds is silently dropped.
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
  r.pendingScroll = n

proc rows*(r: Region): lent seq[string] =
  ## Read accessor for the region's current target rows. Zero-copy
  ## (lent return). Callers use r.rows[i] / r.rows.len / r.rows ==
  ## seq comparisons. The underlying field (`target`) will become
  ## private in slice 2b once all direct accesses are through this
  ## accessor.
  r.target

proc resizeRows*(r: Region, n: int) =
  ## Truncate `target` to at most `n` rows. Matches the inline
  ## `if r.target.len > r.height: r.target.setLen(r.height)` idiom
  ## used in screen.nim's setSize. Grows are not needed here (the
  ## set/setRow procs handle that); this is truncation-only.
  if r.target.len > n:
    r.target.setLen(n)
