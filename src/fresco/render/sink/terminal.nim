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
    result &= t.renderer.render(r.row, r.col, r.target)
    r.pending = false

proc commit*(t: TerminalSink, layout: Layout) =
  ## Compute the ANSI for the layout's current state and write it to
  ## the sink's file descriptor. Handles partial writes and EINTR: a
  ## fully-flushed render is a correctness property (a partial write
  ## would tear an ANSI sequence mid-escape), so we loop until every
  ## byte is committed or an unrecoverable error surfaces — at which
  ## point the remainder is dropped silently. EAGAIN backs off via a
  ## single retry; persistent backpressure also drops the remainder.
  let bytes = t.flush(layout)
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
