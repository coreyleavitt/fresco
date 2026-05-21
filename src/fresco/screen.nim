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
import chronos
import ./render
import ./render/layout
import ./render/sink/terminal
import ./reactive/signal

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
    size*: Signal[(int, int)]
      ## Reactive view of the terminal's (height, width). Bindings
      ## reading this re-run when the terminal resizes — replaces the
      ## old `isResizePending()` polling pattern. Driven by
      ## `setSize` (test-driven or out-of-band reattach) or by
      ## `watchResizes` (SIGWINCH-driven background task).

proc newScreen*(height, width: int, fd: cint = STDERR_FILENO): Screen =
  ## Explicit-size constructor. Used by tests and any caller that
  ## already knows the dimensions; bypasses TIOCGWINSZ.
  Screen(layout: newLayout(height, width),
         sink: newTerminalSink(fd),
         size: signal((height, width)))

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

proc setSize*(s: Screen, height, width: int) =
  ## Update Screen's dimensions to (height, width). Clamps regions that
  ## overflow the new bounds, invalidates the sink's render cache, and
  ## writes the `size` signal so reactive subscribers re-run.
  ##
  ## Called by `watchResizes` after SIGWINCH, by tests driving synthetic
  ## resizes, and by out-of-band reattach handlers (terminal multiplexer
  ## reattach, etc.).
  s.layout.height = height
  s.layout.width  = width
  s.sink.invalidate()
  for r in s.layout.regions:
    if r.row >= height:
      r.height = 0
    elif r.row + r.height > height:
      r.height = height - r.row
    if r.col >= width:
      r.width = 0
    elif r.col + r.width > width:
      r.width = width - r.col
    if r.target.len > r.height:
      r.target.setLen(r.height)
    r.pending = true
  resizePending = false
  s.size.set((height, width))

proc resize*(s: Screen) =
  ## Re-query terminal size from the kernel and apply via setSize.
  ## Kept as a convenience for SIGWINCH-driven callers; new code should
  ## subscribe to `s.size` or use `watchResizes(s)`.
  let (h, w) = queryWinsize(s.fd)
  setSize(s, h, w)

proc watchResizes*(s: Screen): Future[void] {.async: (raises: [CancelledError]).} =
  ## Long-running task that drives `s.size` from SIGWINCH events.
  ##
  ## Polls the process-global `resizePending` flag set by the SIGWINCH
  ## handler (`installResizeHandler` must be called separately). On each
  ## detected change, re-queries the terminal size and calls `setSize`.
  ## Cancel the returned future to stop the loop.
  ##
  ## Polling cadence is 100ms — well below human-perceptible resize
  ## latency, well above the cost of an idle wake. The polling cost is
  ## the price of staying signal-handler-safe without enabling the
  ## thread-required ThreadSignalPtr primitive; the cadence can be
  ## tightened by replacing this with an eventfd / self-pipe path later
  ## behind the same public API.
  while true:
    await sleepAsync(100.milliseconds)
    if resizePending:
      resize(s)
