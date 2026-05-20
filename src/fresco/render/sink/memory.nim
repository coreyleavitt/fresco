## MemorySink — captures Layout content in-memory.
##
## The non-terminal `Sink` impl. Used by headless tests, CI assertion
## mode, notebook snapshot cells, and the sidecar's local-replay
## buffer. Holds no fd; emits no ANSI; just records the composed
## per-row content from a Layout's regions.

import ../layout

type
  MemorySink* = ref object
    rows*: seq[string]
      ## The captured per-row composed content from the most recent
      ## `commit`. Indexed 0..<layout.height. Regions paint into
      ## position; uncovered cells stay blank.

proc newMemorySink*(): MemorySink =
  MemorySink(rows: @[])

proc commit*(s: MemorySink, layout: Layout) =
  ## Capture the layout's current composed state. Each region's
  ## `target` is placed at its (row, col); cells outside any region
  ## stay blank (empty string at the row level — the convention is
  ## that callers querying `rows[i]` get the canonical *visible*
  ## content at that row).
  ##
  ## For single-region-full-layout (the headless single-surface
  ## common case), `rows[i]` is exactly the region's target row,
  ## without padding. For multi-region layouts, this v0 version
  ## takes the *last-painted* region for each row — sufficient for
  ## the headless-validation acceptance criterion. Cell-level
  ## composition for overlapping/adjacent regions is a follow-up
  ## elaboration.
  s.rows = newSeq[string](layout.height)
  for r in layout.regions:
    for i in 0 ..< r.target.len:
      let dstRow = r.row + i
      if dstRow < 0 or dstRow >= layout.height: continue
      s.rows[dstRow] = r.target[i]
    r.pending = false
    r.pendingScroll = 0
