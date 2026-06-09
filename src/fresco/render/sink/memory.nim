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
    committedRows*: seq[string]
      ## Accumulated committed (scrollback) lines from all
      ## `commitInline` and `teardownFlush` calls. Appended on every
      ## drain; never reset between calls — reflects the full
      ## committed history in order. Empty for callers that do not
      ## use InlineScreen (plain MemorySink.commit never writes here).

proc newMemorySink*(): MemorySink =
  MemorySink(rows: @[], committedRows: @[])

proc writeAll*(s: MemorySink, bytes: string) = discard
  ## No-op: MemorySink has no fd to write to. Exists so the
  ## `when compiles(s.sink.writeAll(...))` branch in inline_screen
  ## compiles for MemorySink (TerminalSink path) without actually
  ## emitting anything — MemorySink's commitInline handles output
  ## capture directly.

proc commitInline*(s: MemorySink, layout: Layout,
                   committed: seq[string],
                   liveTop, inputRow, inputCol: int): string =
  ## Inline commit handler for InlineScreen[MemorySink].
  ## Appends `committed` to `s.committedRows` (the committed scrollback
  ## capture) and re-renders the live band into `s.rows` (preserving
  ## the same capture semantics as `commit`).
  ##
  ## Returns `""` — MemorySink has no byte output. The return value
  ## satisfies the `commitInline` contract so `writeAll(s, "")` is
  ## a harmless no-op.
  ##
  ## Called exclusively by `commitOneBatch` in inline_screen.nim via the
  ## `when compiles(s.sink.commitInline(...))` branch. The MemorySink
  ## path never falls through to `s.paint()`.
  for line in committed:
    s.committedRows.add(line)
  # Re-render the live band into rows.
  s.rows = newSeq[string](layout.height)
  for r in layout.regions:
    for i in 0 ..< r.rows.len:
      let dstRow = r.row + i
      if dstRow < 0 or dstRow >= layout.height: continue
      s.rows[dstRow] = r.rows[i]
    r.pending = false
    r.pendingScroll = 0
  result = ""

proc invalidate*(s: MemorySink) = discard
  ## No-op: MemorySink has no render cache. Each `commit` captures
  ## fresh from the layout's regions, so there's nothing to invalidate
  ## on resize. Exists so `Screen[S].setSize` can call `s.sink.invalidate()`
  ## without a compile-time branch on S.

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
    for i in 0 ..< r.rows.len:
      let dstRow = r.row + i
      if dstRow < 0 or dstRow >= layout.height: continue
      s.rows[dstRow] = r.rows[i]
    r.pending = false
    r.pendingScroll = 0
