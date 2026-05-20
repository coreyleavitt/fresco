## Screen — terminal-rendering convenience that bundles Layout + TerminalSink.
##
## Post-Phase-2 split, `Screen` is a thin compatibility wrapper. The
## underlying architecture is `Layout` (spatial coordination, in
## `render/layout.nim`) + `TerminalSink` (ANSI emission, in
## `render/sink/terminal.nim`). New code can use those primitives
## directly — or use Screen for the common case of "I want a Layout
## paired with a TerminalSink writing to stderr."
##
## SIGWINCH plumbing remains here because resize-detection is
## terminal-specific and stateful across the whole process.

import std/posix
import ./render
import ./render/layout
import ./render/sink/terminal

export layout.Region, layout.set, layout.markDirty, layout.setRow, layout.scrollUp

# --- TIOCGWINSZ bindings --------------------------------------------------

type
  IOctlWinSize {.importc: "struct winsize",
                 header: "<sys/ioctl.h>".} = object
    ws_row, ws_col, ws_xpixel, ws_ypixel: cushort

var TIOCGWINSZ {.importc, header: "<sys/ioctl.h>".}: culong
var SIGWINCH {.importc, header: "<signal.h>".}: cint

proc ioctl(fd: cint, request: culong, arg: pointer): cint
  {.importc, header: "<sys/ioctl.h>".}

proc queryWinsize*(fd: cint): tuple[height, width: int] =
  ## Returns (rows, cols). Falls back to (24, 80) when ioctl fails
  ## (e.g. `fd` isn't a TTY).
  var ws: IOctlWinSize
  if ioctl(fd, TIOCGWINSZ, addr ws) == 0 and ws.ws_row > 0'u16 and ws.ws_col > 0'u16:
    return (int(ws.ws_row), int(ws.ws_col))
  return (24, 80)

# --- Screen: Layout + TerminalSink wrapper --------------------------------

type
  Screen* = ref object
    layout*: Layout
    sink*: TerminalSink

proc newScreen*(height, width: int, fd: cint = STDERR_FILENO): Screen =
  ## Explicit-size constructor. Used by tests and any caller that
  ## already knows the dimensions; bypasses TIOCGWINSZ.
  Screen(layout: newLayout(height, width),
         sink: newTerminalSink(fd))

proc newScreen*(fd: cint = STDERR_FILENO): Screen =
  let (h, w) = queryWinsize(fd)
  newScreen(h, w, fd)

proc height*(s: Screen): int {.inline.} = s.layout.height
proc width*(s: Screen): int {.inline.} = s.layout.width
proc fd*(s: Screen): cint {.inline.} = s.sink.fd
proc regions*(s: Screen): seq[Region] {.inline.} = s.layout.regions

# Setters so tests/callers can mutate Screen.height / Screen.width
# directly — preserves the field-syntax API from the pre-split Screen.
proc `height=`*(s: Screen, v: int) {.inline.} = s.layout.height = v
proc `width=`*(s: Screen, v: int) {.inline.} = s.layout.width = v

proc newRegion*(s: Screen, row, col, height, width: int): Region =
  ## Allocate a Region on this Screen's underlying Layout.
  newRegion(s.layout, row, col, height, width)

proc flush*(s: Screen): string =
  ## Returns the ANSI bytes needed to bring the screen to its target
  ## state. Idempotent: a second flush with no changes returns "".
  s.sink.flush(s.layout)

proc paint*(s: Screen) =
  ## Convenience: flush + write the resulting bytes to `s.fd`.
  ## Handles partial writes + EINTR internally.
  s.sink.commit(s.layout)

# --- SIGWINCH -------------------------------------------------------------

var resizePending: bool
  ## Process-wide flag set by the SIGWINCH handler. Callers read via
  ## `isResizePending()` and reset it by calling `resize()`.

proc isResizePending*(): bool = resizePending

proc winchHandler(sig: cint) {.noconv.} =
  resizePending = true

proc installResizeHandler*() =
  ## Installs a SIGWINCH handler that sets the resize-pending flag.
  ## Callers poll via `isResizePending()` and call `resize()` when
  ## it's true; signal handlers can't safely mutate Nim seqs.
  discard signal(SIGWINCH, winchHandler)

proc uninstallResizeHandler*() =
  discard signal(SIGWINCH, SIG_DFL)
  resizePending = false

proc resize*(s: Screen) =
  ## Re-query terminal size, resize the renderer, mark every region
  ## pending. Regions that no longer fit are clamped in place.
  let (h, w) = queryWinsize(s.fd)
  s.layout.height = h
  s.layout.width  = w
  # Drop the sink's renderer cache — terminal contents are now unknown.
  s.sink.invalidate()
  for r in s.layout.regions:
    if r.row >= h:
      r.height = 0
    elif r.row + r.height > h:
      r.height = h - r.row
    if r.col >= w:
      r.width = 0
    elif r.col + r.width > w:
      r.width = w - r.col
    if r.target.len > r.height:
      r.target.setLen(r.height)
    r.pending = true
  resizePending = false
