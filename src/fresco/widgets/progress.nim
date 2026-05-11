## Progress group: multiple concurrent inline indicators.
##
## Each item renders as one row: spinner glyph (or ✔/✘ on completion)
## + label + optional detail. The group renders into a region; the
## caller drives the spinner by calling `tick` on a timer.

import ../screen
import ../terminal/ansi

const SpinnerFrames* =
  ["|", "/", "-", "\\"]
  ## ASCII spinner for v0 (compat-safe). Replace with braille ⠋⠙⠹...
  ## later if we want to drop terminals that don't render fine glyphs.

type
  ProgressState* = enum
    psRunning
    psDone
    psFailed

  ProgressItem* = ref object
    label*: string
    detail*: string
    state*: ProgressState

  ProgressGroup* = ref object
    region*: Region
    items*: seq[ProgressItem]
    tick*: int

proc newProgressGroup*(region: Region): ProgressGroup =
  ProgressGroup(region: region, items: @[], tick: 0)

proc addItem*(g: ProgressGroup, label: string,
              detail = ""): ProgressItem =
  result = ProgressItem(label: label, detail: detail, state: psRunning)
  g.items.add result

proc setDetail*(item: ProgressItem, detail: string) =
  item.detail = detail

proc complete*(item: ProgressItem, detail = "") =
  item.state = psDone
  if detail.len > 0: item.detail = detail

proc fail*(item: ProgressItem, detail = "") =
  item.state = psFailed
  if detail.len > 0: item.detail = detail

proc advanceTick*(g: ProgressGroup) =
  g.tick = (g.tick + 1) mod SpinnerFrames.len

proc glyph(item: ProgressItem, tick: int): string =
  case item.state
  of psRunning: color(SpinnerFrames[tick mod SpinnerFrames.len], cCyan)
  of psDone:    color("v", cGreen)
  of psFailed:  color("x", cRed)

proc renderRow(item: ProgressItem, tick: int): string =
  let head = glyph(item, tick) & " " & item.label
  if item.detail.len > 0:
    head & " " & dim(item.detail)
  else:
    head

proc render*(g: ProgressGroup) =
  ## Build a row per item; pad with blank rows; clip excess.
  let h = g.region.height
  var rows = newSeq[string](h)
  let n = min(h, g.items.len)
  for i in 0 ..< n:
    rows[i] = renderRow(g.items[i], g.tick)
  g.region.set(rows)
