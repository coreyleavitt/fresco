## Append-only scrollback buffer over a Region.
##
## `append` adds a line; `render` updates the region's target to show
## the rows visible at the current `offset`. Default behavior is tail
## mode (offset = 0 → bottom of buffer pinned). `enterBrowse` /
## `scrollUp` / `scrollDown` walk older content; `exitBrowse` or
## `scrollToBottom` returns to tail mode.
##
## When the buffer exceeds `maxLines`, the oldest entries are dropped.
## The viewport offset is shifted to compensate so the user's current
## position doesn't visibly jump.

import ./screen

type
  Scrollback* = ref object
    region*: Region
    lines*: seq[string]
    maxLines*: int
    offset*: int          # rows above the bottom that are pinned at the viewport bottom
    browsing*: bool

proc newScrollback*(region: Region, maxLines = 10_000): Scrollback =
  doAssert maxLines > 0
  Scrollback(region: region, lines: @[],
             maxLines: maxLines, offset: 0, browsing: false)

proc maxOffset*(s: Scrollback): int =
  max(0, s.lines.len - s.region.height)

proc append*(s: Scrollback, line: string) =
  s.lines.add line
  if s.lines.len > s.maxLines:
    let drop = s.lines.len - s.maxLines
    s.lines = s.lines[drop .. ^1]
  # Clamp offset to the new max; do not actively decrement on drop —
  # the surviving lines remain at the same offset-from-bottom anchor.
  if s.offset > s.maxOffset: s.offset = s.maxOffset

proc scrollUp*(s: Scrollback, n = 1) =
  s.offset = min(s.maxOffset, s.offset + n)
  s.browsing = s.offset > 0

proc scrollDown*(s: Scrollback, n = 1) =
  s.offset = max(0, s.offset - n)
  if s.offset == 0: s.browsing = false

proc enterBrowse*(s: Scrollback) =
  s.browsing = true

proc exitBrowse*(s: Scrollback) =
  s.browsing = false
  s.offset = 0

proc scrollToBottom*(s: Scrollback) =
  s.offset = 0
  s.browsing = false

proc atBottom*(s: Scrollback): bool = s.offset == 0

proc render*(s: Scrollback) =
  ## Write the current viewport to `region.target`. Always emits a
  ## seq of exactly `region.height` entries; rows above the start of
  ## history are blank strings.
  let h = s.region.height
  let bottomIdx = s.lines.len - 1 - s.offset
  let topIdx = bottomIdx - h + 1
  var window = newSeq[string](h)
  for i in 0 ..< h:
    let idx = topIdx + i
    window[i] = if idx >= 0 and idx < s.lines.len: s.lines[idx] else: ""
  s.region.set(window)
