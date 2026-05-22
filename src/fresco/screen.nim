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
import ./render/sink
import ./render/sink/terminal
import ./reactive/signal

# Re-export so consumers of Screen automatically see TerminalSink's
# commit/invalidate/flush — required for the Sink concept to verify
# `TerminalSink` satisfies it at generic-instantiation sites in
# downstream code. Non-default sinks (MemorySink, future sinks) must
# be imported explicitly by their consumers.
export terminal

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
  Screen*[S: Sink] = ref object
    layout*: Layout
    sink*: S
    size*: Signal[(int, int)]
      ## Reactive view of the screen's (height, width). Bindings
      ## reading this re-run when the screen is resized — replaces the
      ## old `isResizePending()` polling pattern. Driven by
      ## `setSize` (test-driven or out-of-band reattach) or by
      ## `watchResizes` (SIGWINCH-driven background task; terminal only).

  TerminalScreen* = Screen[TerminalSink]
    ## Production screen: ANSI emission to a file descriptor, SIGWINCH-
    ## driven resize. Default for `newScreen()` with no sink arg.

proc newScreen*(height, width: int, fd: cint = STDERR_FILENO): TerminalScreen =
  ## Explicit-size constructor with the default TerminalSink. The most
  ## common entry point: production apps that already know the
  ## dimensions (e.g. amoxtli sizing its panel against a parent layout).
  TerminalScreen(layout: newLayout(height, width),
                 sink: newTerminalSink(fd),
                 size: signal((height, width)))

proc newScreen*[S: Sink](sink: S, height, width: int): Screen[S] =
  ## Explicit-sink constructor. Used by tests (with MemorySink) and any
  ## non-default sink choice (file, websocket, IPC). No TIOCGWINSZ —
  ## the caller knows the synthetic dimensions.
  Screen[S](layout: newLayout(height, width),
            sink: sink,
            size: signal((height, width)))

proc newScreen*(fd: cint = STDERR_FILENO): TerminalScreen =
  ## TIOCGWINSZ-querying constructor. Used by production apps that
  ## paint to the real terminal.
  let (h, w) = queryWinsize(fd)
  newScreen(h, w, fd)

proc height*[S: Sink](s: Screen[S]): int {.inline.} = s.layout.height
proc width*[S: Sink](s: Screen[S]): int {.inline.} = s.layout.width
proc regions*[S: Sink](s: Screen[S]): seq[Region] {.inline.} = s.layout.regions

proc fd*(s: TerminalScreen): cint {.inline.} = s.sink.fd
  ## Only meaningful for TerminalScreen; MemoryScreen has no file
  ## descriptor (commits to in-memory rows).

proc newRegion*[S: Sink](s: Screen[S], row, col, height, width: int): Region =
  ## Allocate a Region on this Screen's underlying Layout. Generic
  ## across sink type because regions are spatial coordination only —
  ## they don't know how the sink emits.
  newRegion(s.layout, row, col, height, width)

proc flush*(s: TerminalScreen): string =
  ## Returns the ANSI bytes needed to bring the terminal to its target
  ## state. Idempotent: a second flush with no changes returns "".
  ## Terminal-only — MemoryScreen doesn't emit bytes.
  s.sink.flush(s.layout)

proc paint*[S: Sink](s: Screen[S]) =
  ## Commit the layout through the sink. For TerminalScreen this emits
  ## ANSI to the fd; for MemoryScreen it captures rows; for any other
  ## sink it does whatever that sink's `commit` does.
  mixin commit
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

proc setSize*[S: Sink](s: Screen[S], height, width: int) =
  ## Update Screen's dimensions to (height, width). Clamps regions that
  ## overflow the new bounds, invalidates the sink's render cache, and
  ## writes the `size` signal so reactive subscribers re-run.
  ##
  ## Called by `watchResizes` after SIGWINCH, by tests driving synthetic
  ## resizes, and by out-of-band reattach handlers (terminal multiplexer
  ## reattach, etc.).
  mixin invalidate
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

proc resize*(s: TerminalScreen) =
  ## Re-query terminal size from the kernel and apply via setSize.
  ## Kept as a convenience for SIGWINCH-driven callers; new code should
  ## subscribe to `s.size` or use `watchResizes(s)`. Terminal-only —
  ## MemoryScreen has no kernel to query.
  let (h, w) = queryWinsize(s.fd)
  setSize(s, h, w)

proc watchResizes*(s: TerminalScreen): Future[void] {.async: (raises: [CancelledError]).} =
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
