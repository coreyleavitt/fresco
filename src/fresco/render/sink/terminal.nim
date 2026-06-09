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

import std/posix
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

proc flush*(t: TerminalSink, layout: Layout): string =
  ## Compute the ANSI byte string needed to bring the terminal to
  ## match the layout's current state — without writing it. Used by
  ## tests that want to inspect the bytes. `commit` is the normal
  ## form (computes the bytes AND writes them to the fd).
  if t.renderer == nil or
     t.lastHeight != layout.height or
     t.lastWidth  != layout.width:
    t.renderer = newRenderer(layout.height, layout.width)
    t.lastHeight = layout.height
    t.lastWidth  = layout.width

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

proc ensureRenderer(t: TerminalSink, layout: Layout) {.inline.} =
  ## Size the renderer lazily, matching the flush lazy-init block.
  if t.renderer == nil or
     t.lastHeight != layout.height or
     t.lastWidth  != layout.width:
    t.renderer = newRenderer(layout.height, layout.width)
    t.lastHeight = layout.height
    t.lastWidth  = layout.width

proc commitInline*(t: TerminalSink, layout: Layout, committed: seq[string],
                   liveTop, inputRow, inputCol: int): string =
  ## Compute-only inline commit pipeline. Returns the full ANSI byte string;
  ## does NOT write to the fd (caller calls writeAll). Mutates the renderer
  ## cache and region pending/pendingScroll fields.
  ##
  ## Step order (load-bearing — round-3 CRITICALs):
  ##   2. Pre-drain pendingScroll + cursor-to-top of live band.
  ##   4. Print committed lines raw (native scroll into history).
  ##   5. Invalidate live-band cache AFTER committed emit, BEFORE repaint.
  ##   6. Repaint live band at the regions' unchanged rows.
  ##   7. Cursor → input point.

  # Size the renderer lazily (same logic as flush).
  ensureRenderer(t, layout)

  # Step 2: pre-drain pendingScroll for each region, then cursor to liveTop.
  for r in layout.regions:
    if r.pendingScroll != 0:
      result &= t.renderer.scrollUpRegion(
        r.row, r.row + r.height - 1, r.pendingScroll)
      r.pendingScroll = 0
  # scrollUpRegion leaves cursor at (1,1); emit an explicit cursorTo before
  # any committed-line print so position is well-defined (CRITICAL-2).
  result &= cursorTo(liveTop + 1, 1)

  # Step 4: print committed lines raw (unclipped — native scroll into history).
  # Also compute the measured physical height for cursor accounting and
  # debug assertions. With an explicit absolute cursorTo the final position
  # is deterministic; measured feeds the debug doAssert and documents where
  # native-scroll coherence relies on the cache invalidate, not cursor arithmetic.
  var measured = 0
  for line in committed:
    measured += physicalRows(line, layout.width)
    result &= line & "\n"
  when compileOption("assertions"):
    doAssert measured >= committed.len,
      "commitInline: measured physical rows " & $measured &
      " < committed.len " & $committed.len & " — physicalRows invariant violated"

  # Step 5: invalidate the live-band renderer cache AFTER committed emit,
  # BEFORE repaint (CRITICAL-1 — fresco owns only the band; external scroll
  # has repositioned the terminal and cache rows no longer match what's on
  # screen).
  t.renderer.invalidate()

  # Step 6: repaint the live band at the regions' UNCHANGED rows.
  for r in layout.regions:
    result &= t.renderer.render(r.row, r.col, r.rows)
    r.pending = false

  # Step 7: cursor → input point (1-based).
  result &= cursorTo(inputRow + 1, inputCol + 1)
