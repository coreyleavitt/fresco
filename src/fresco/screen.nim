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

  ScreenLike* = concept s
    ## Structural concept describing the observable surface of a screen.
    ## Consumers that just need to operate on "anything screen-shaped"
    ## (e.g. future trace frontends, alternative spatial models) can
    ## take a `ScreenLike` instead of pinning to `Screen[S]`. Today's
    ## fresco consumers use `Screen[S]` directly; ScreenLike is the
    ## opt-in flexibility for non-Screen sibling frontends.
    s.layout is Layout
    s.size is Signal[(int, int)]

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
#
# Self-pipe trick. POSIX signal handlers can call only async-signal-safe
# functions; `write(2)` to a pipe IS safe but firing a chronos AsyncEvent
# is not (the callback list can do arbitrary work). The handler writes
# one byte to a non-blocking pipe; `watchResizes` registers the read end
# with the chronos dispatcher and wakes the instant the byte arrives.
# Zero idle wakeups, immediate-response latency.

var
  winchPipe: array[2, cint] = [-1.cint, -1.cint]
    ## [read, write] fds of the self-pipe. Initialized by
    ## `installResizeHandler`; cleared by `uninstallResizeHandler`.
  winchRegistered: bool
    ## Tracks whether the read fd is registered with chronos so we know
    ## whether to unregister it on teardown. Distinct from `winchPipe[0]
    ## != -1` because the dispatcher may not exist at install time.
  resizePending: bool
    ## Process-wide flag mirroring whether a SIGWINCH has been delivered
    ## since last drain. Kept for `isResizePending()` compatibility; new
    ## code subscribes to the size signal instead.

proc isResizePending*(): bool {.deprecated: "subscribe to screen.size".} =
  resizePending

proc winchHandler(sig: cint) {.noconv.} =
  # Async-signal-safe path only: write one byte, set the flag. Nim
  # seqs and the GC are off-limits here.
  resizePending = true
  if winchPipe[1] >= 0:
    var b = byte('x')
    discard write(winchPipe[1], addr b, 1)

proc installResizeHandler*() =
  ## Open the SIGWINCH self-pipe and install the signal handler. Safe
  ## to call multiple times — second + subsequent calls reuse the
  ## existing pipe.
  if winchPipe[0] < 0:
    doAssert pipe(winchPipe) == 0, "fresco: SIGWINCH pipe() failed"
    # Non-blocking on both ends. Read returns EAGAIN when drained;
    # write from the handler never blocks even under burst SIGWINCH.
    discard fcntl(winchPipe[0], F_SETFL, O_NONBLOCK)
    discard fcntl(winchPipe[1], F_SETFL, O_NONBLOCK)
  discard signal(SIGWINCH, winchHandler)

proc uninstallResizeHandler*() =
  discard signal(SIGWINCH, SIG_DFL)
  resizePending = false
  if winchRegistered and winchPipe[0] >= 0:
    try: unregister(AsyncFD(winchPipe[0])) except CatchableError: discard
    winchRegistered = false
  for i in 0 .. 1:
    if winchPipe[i] >= 0:
      discard close(winchPipe[i])
      winchPipe[i] = -1

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

proc waitWinchByte(): Future[void] {.async.} =
  ## Suspend until the SIGWINCH self-pipe is readable, then drain it.
  ## Uses chronos's `addReader` for zero-wakeup wait — the dispatcher
  ## fires the callback only when bytes actually arrive on the pipe.
  let fd = AsyncFD(winchPipe[0])
  if not winchRegistered:
    try: register(fd) except OSError: discard
    winchRegistered = true
  let fut = newFuture[void]("fresco.winchPipe")
  proc onReadable(udata: pointer) {.gcsafe.} =
    if not fut.finished():
      fut.complete()
  try: addReader(fd, onReadable)
  except OSError: discard
  try:
    await fut
  finally:
    try: removeReader(fd) except OSError: discard
  # Drain whatever arrived; multiple SIGWINCHes can coalesce into one
  # wake. Returns to the loop which calls resize once.
  var buf: array[64, byte]
  while true:
    let n = posix.read(winchPipe[0], addr buf, sizeof(buf))
    if n <= 0: break

proc watchResizes*(s: TerminalScreen): Future[void] {.async.} =
  ## Long-running task that drives `s.size` from SIGWINCH events.
  ##
  ## Sleeps on the SIGWINCH self-pipe (registered with chronos's
  ## dispatcher). On wake — i.e. when the signal handler has written
  ## a byte — drains the pipe, re-queries the terminal size, and calls
  ## `setSize`. Zero idle wakeups; immediate response.
  ##
  ## `installResizeHandler()` must have been called before this future
  ## is awaited. Cancel the returned future to stop the loop.
  doAssert winchPipe[0] >= 0,
    "fresco: watchResizes requires installResizeHandler() first"
  while true:
    await waitWinchByte()
    resize(s)
