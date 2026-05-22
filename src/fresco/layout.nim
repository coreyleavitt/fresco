## Vertical stack layout.
##
## Caller declares a list of weights; layout assigns each slot a
## contiguous row range proportional to its weight. On SIGWINCH the
## caller calls `relayout` to redistribute over the new screen size.
##
## No flexbox, no min/max constraints in v0 — just proportions. A slot
## may receive 0 rows if the available area is too small for its share;
## the renderer's row-clipping handles that case.

import std/math
import ./screen
import ./render/sink

type
  VStack*[S: Sink] = ref object
    screen*: Screen[S]
    weights*: seq[int]
    top*, left*, width*: int
    height*: int           # -1 means "screen.height - top"
    regions*: seq[Region]

proc effectiveHeight[S: Sink](v: VStack[S]): int =
  if v.height < 0: v.screen.height - v.top else: v.height

proc effectiveWidth[S: Sink](v: VStack[S]): int =
  if v.width < 0: v.screen.width - v.left else: v.width

proc splitRows*(total: int, weights: openArray[int]): seq[(int, int)] =
  ## Returns `(rowStart, height)` for each weight. Heights sum to
  ## exactly `total` (any rounding remainder is folded into the last
  ## non-zero-weight slot).
  result = newSeq[(int, int)](weights.len)
  if weights.len == 0 or total <= 0: return
  let totalW = weights.sum
  doAssert totalW > 0, "vstack weights must sum to > 0"
  var cursor = 0
  var allocated = 0
  let lastIdx = weights.high
  for i, w in weights:
    let h =
      if i == lastIdx: total - allocated
      else: (total * w) div totalW
    result[i] = (cursor, h)
    cursor += h
    allocated += h

proc applyGeometry[S: Sink](v: VStack[S]) =
  let h = effectiveHeight(v)
  let w = effectiveWidth(v)
  let slots = splitRows(h, v.weights)
  doAssert v.regions.len == v.weights.len
  for i, slot in slots:
    v.regions[i].row    = v.top + slot[0]
    v.regions[i].col    = v.left
    v.regions[i].height = slot[1]
    v.regions[i].width  = w
    v.regions[i].markDirty()

proc newVStack*[S: Sink](screen: Screen[S],
                          weights: openArray[int],
                          top = 0, left = 0,
                          height = -1, width = -1): VStack[S] =
  ## Create the stack and the underlying Regions. Regions are sized
  ## proportionally; you can `set` content on each one as usual.
  result = VStack[S](
    screen: screen,
    weights: @weights,
    top: top, left: left,
    height: height, width: width,
    regions: @[],
  )
  let h = effectiveHeight(result)
  let w = effectiveWidth(result)
  let slots = splitRows(h, result.weights)
  for i, slot in slots:
    let region = newRegion(screen,
      row    = top + slot[0],
      col    = left,
      height = max(slot[1], 1),
      width  = w)
    # Bounds-checking inside newRegion requires height >= 1; if the
    # actual share rounded to 0 we still allocate a 1-row region, but
    # callers should detect this by inspecting result.regions[i].height
    # via the splitRows output rather than the region object itself.
    region.height = slot[1]
    result.regions.add region

proc relayout*[S: Sink](v: VStack[S]) =
  ## Recompute geometry against the screen's current size. Call this
  ## after `screen.resize()` fires on SIGWINCH.
  applyGeometry(v)
