## TerminalSink — emits ANSI to a file descriptor.
##
## The terminal-frontend `Sink` impl. Owns a `Renderer` (the per-row
## diff cache that tracks what the terminal currently shows) and a
## file descriptor (defaults to STDERR; CLAUDE.md non-negotiable:
## library output goes to stderr, not stdout, which belongs to the
## caller's pipe).
##
## Lazy renderer allocation: the first commit, or any commit where
## the layout's dimensions differ from the cached renderer's, builds
## a fresh `Renderer`. This handles resize without callers having to
## manage renderer state.

import std/[posix, algorithm]
import ../layout
import ../../render
import ../../terminal/ansi

type
  TerminalSink* = ref object
    fd*: cint
    renderer: Renderer
      ## Lazily allocated on first commit; resized on dimension change.
    lastHeight, lastWidth: int
      ## Mirrored from the layout the renderer was sized for. Compared
      ## on each commit to detect resize.

proc newTerminalSink*(fd: cint = STDERR_FILENO): TerminalSink =
  TerminalSink(fd: fd, renderer: nil, lastHeight: 0, lastWidth: 0)

proc invalidate*(t: TerminalSink) =
  ## Drop the renderer's cached snapshot. Next commit emits every
  ## row even if its content is unchanged from the cache. Use on
  ## alt-screen enter/leave or after any out-of-band emission that
  ## the renderer didn't see (e.g., a third party writing to the fd).
  if t.renderer != nil:
    t.renderer.invalidate()

proc ensureRenderer*(t: TerminalSink, layout: Layout) {.inline.} =
  ## Lazily allocate (or resize) the renderer to match the layout's current
  ## dimensions. Called from `flush` and `commitInline` — the single
  ## authoritative lazy-init path. Both used to duplicate this block; now
  ## each delegates here.
  if t.renderer == nil or
     t.lastHeight != layout.height or
     t.lastWidth  != layout.width:
    t.renderer = newRenderer(layout.height, layout.width)
    t.lastHeight = layout.height
    t.lastWidth  = layout.width

proc flush*(t: TerminalSink, layout: Layout): string =
  ## Compute the ANSI byte string needed to bring the terminal to
  ## match the layout's current state — without writing it. Used by
  ## tests that want to inspect the bytes. `commit` is the normal
  ## form (computes the bytes AND writes them to the fd).
  ensureRenderer(t, layout)

  result = ""
  for r in layout.regions:
    if r.pendingScroll != 0:
      result &= t.renderer.scrollUpRegion(
        r.row, r.row + r.height - 1, r.pendingScroll)
      r.pendingScroll = 0
    if not r.pending: continue
    result &= t.renderer.render(r.row, r.col, r.rows)
    r.pending = false

proc writeAll*(t: TerminalSink, bytes: string) =
  ## Write `bytes` to the sink's file descriptor with partial-write /
  ## EINTR retry semantics. A fully-flushed write is a correctness
  ## property (a partial write would tear an ANSI sequence mid-escape),
  ## so we loop until every byte is written or an unrecoverable error
  ## surfaces — at which point the remainder is dropped silently.
  if bytes.len == 0: return
  var written = 0
  while written < bytes.len:
    let n = posix.write(t.fd, unsafeAddr bytes[written], bytes.len - written)
    if n > 0:
      written += n
    elif errno == EINTR:
      continue
    else:
      break

proc commit*(t: TerminalSink, layout: Layout) =
  ## Compute the ANSI for the layout's current state and write it to
  ## the sink's file descriptor. Delegates to flush + writeAll.
  t.writeAll(t.flush(layout))

proc commitInline*(t: TerminalSink, layout: Layout, committed: seq[string],
                   liveTop, inputRow, inputCol: int): string =
  ## Compute-only inline commit pipeline. Returns the full ANSI byte string;
  ## does NOT write to the fd (caller calls writeAll). Mutates the renderer
  ## cache and region pending/pendingScroll fields.
  ##
  ## ## Geometry contract
  ##
  ## InlineScreen regions are bottom-anchored: they occupy the last rows of
  ## the terminal (rows `liveTop .. H-1`, 0-based). Committed content spills
  ## into the rows above the band and native scrollback.
  ##
  ## ## Emit algorithm (relative-flow newline stream)
  ##
  ## 1. Pre-drain pendingScroll for each live-band region (step 2).
  ## 2. `cursorTo(liveTop+1, 1)` — position at the top row of the band (1-based).
  ## 3. `ESC [ 0 J` (ED 0) — erase from cursor to end of screen, clearing the
  ##    old band content.
  ## 4. Emit as one relative-flow stream (each item followed by `"\n"`):
  ##    a. The N committed lines RAW (unclipped — committed is the raw path).
  ##    b. The live-zone region rows in ascending physical-row order, each
  ##       CLIPPED to its width (already clipped by Region.set/setRow).
  ##    Because we emit `N + bandHeight` lines starting from `liveTop+1` but
  ##    only `bandHeight` rows exist from there to row H, the terminal performs
  ##    N native scroll events. The committed lines (emitted first) are pushed
  ##    UP to rows just above the band (rows `liveTop-N .. liveTop-1`), with
  ##    the oldest scrolling into native scrollback once they pass row 1. The
  ##    band rows (emitted last) land back at `[liveTop .. H-1]`. This is the
  ##    canonical "print above a status line" technique.
  ## 5. Invalidate the renderer diff cache (the relative emit moved physical
  ##    content; the cache must not believe stale absolute rows). Set each
  ##    region's `pending=false` (we just emitted their content). The next
  ##    `paint()` call after a `set()/setRow()` marks pending=true and the
  ##    invalidated cache forces a full absolute-CUP repaint — coherent.
  ## 6. `cursorTo(inputRow+1, inputCol+1)` — restore the cursor to the input
  ##    point within the live band.
  ##
  ## ## Why the physicalRows assertion was dropped
  ##
  ## The old algorithm (print-at-top + scroll-from-bottom) used physicalRows
  ## for cursor accounting to determine how many native-scroll newlines to emit.
  ## The relative-flow algorithm does not need cursor accounting: it emits
  ## exactly N committed lines + bandHeight band rows from liveTop+1, and the
  ## terminal handles the scrolling mechanically. physicalRows is vacuous here.

  # Size the renderer lazily — delegates to ensureRenderer (shared with flush).
  ensureRenderer(t, layout)

  # Step 2: pre-drain pendingScroll for each region.
  for r in layout.regions:
    if r.pendingScroll != 0:
      result &= t.renderer.scrollUpRegion(
        r.row, r.row + r.height - 1, r.pendingScroll)
      r.pendingScroll = 0

  # Step 3: position at the top of the live band (1-based) and erase to end of screen.
  result &= cursorTo(liveTop + 1, 1)
  result &= "\x1b[0J"

  # Step 4a: collect band rows first so we know whether committed lines are
  # followed by band rows (affects newline termination — see step 4b).
  type RowEntry = tuple[absRow: int, content: string]
  var bandRows: seq[RowEntry]
  for r in layout.regions:
    let targetRows = r.rows  # lent — zero-copy view
    for i in 0 ..< r.height:
      let content = if i < targetRows.len: targetRows[i] else: ""
      bandRows.add((r.row + i, content))
  bandRows.sort(proc(a, b: RowEntry): int = cmp(a.absRow, b.absRow))

  # Emit committed lines RAW (unclipped — the raw path; terminal handles wrap).
  # Each committed line is followed by \n to advance the cursor.
  for line in committed:
    result &= line & "\n"

  # Step 4b: emit live-zone region rows in ascending physical-row order,
  # each CLIPPED (already applied by Region.set/setRow).
  #
  # Newline discipline: every item EXCEPT the last band row gets a trailing
  # \n. The last band row must NOT get a trailing \n, because a \n at the
  # terminal bottom row triggers a native scroll that would shift the band
  # up by one more row than intended.
  #
  # Worked N=1, bandH=2, H=10, liveTop=8 example:
  #   cursorTo(9,1) positions at row 8 (0-based).
  #   "committed\n"   → write row 8, cursor → row 9 (no scroll: 8 < 9)
  #   "band-row-0\n"  → write row 9, \n → scroll #1: band-row-0 → row 8, blank row 9
  #   "band-row-1"    → write row 9, NO \n: no scroll.
  #   Result: committed at row 7 (above band), band at rows 8-9. ✓
  for i, entry in bandRows:
    let isLast = (i == bandRows.len - 1)
    if isLast:
      result &= entry.content        # no trailing \n on last row
    else:
      result &= entry.content & "\n"

  # Step 5: invalidate the renderer diff cache and mark regions not-pending.
  # The relative-flow emit moved physical content; absolute-row cache entries
  # are no longer valid. The next paint() after a set()/setRow() marks
  # pending=true and the invalidated cache forces a fresh absolute repaint.
  t.renderer.invalidate()
  for r in layout.regions:
    r.pending = false

  # Step 6: cursor → input point (1-based).
  result &= cursorTo(inputRow + 1, inputCol + 1)
