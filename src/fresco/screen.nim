## Screen + Region: geometry, bounds checking, and SIGWINCH plumbing.
##
## A `Screen` owns the total terminal area and a `Renderer` over it.
## A `Region` is a sub-rectangle whose `set(content)` queues a target;
## `screen.flush()` walks pending regions and returns the ANSI bytes
## the caller writes (typically to stderr — DESIGN.md L5).
##
## SIGWINCH: `installResizeHandler()` arms a process-global flag that
## the caller polls between dispatcher ticks (signal handlers can't
## safely mutate seqs). On detection, `resize()` re-queries TIOCGWINSZ
## and invalidates the renderer + every region.

import std/posix
import ./render

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

# --- Region + Screen ------------------------------------------------------

type
  Region* = ref object
    screen*: Screen
    row*, col*, height*, width*: int
    target*: seq[string]
    pending*: bool
    pendingScroll*: int
      ## When non-zero, the next flush emits a DECSTBM scroll-up of
      ## the region by this many lines BEFORE running the target diff.
      ## Reset to 0 after flushing. Used by `bindCollection` in
      ## wmFromEnd mode to optimize tail-append into one ANSI scroll
      ## command + one row paint instead of N row repaints.

  Screen* = ref object
    fd*: cint
    height*, width*: int
    renderer*: Renderer
    regions*: seq[Region]

proc newScreen*(height, width: int, fd: cint = STDERR_FILENO): Screen =
  ## Explicit-size constructor. Used by tests and any caller that
  ## already knows the dimensions; bypasses TIOCGWINSZ.
  Screen(fd: fd, height: height, width: width,
         renderer: newRenderer(height, width))

proc newScreen*(fd: cint = STDERR_FILENO): Screen =
  let (h, w) = queryWinsize(fd)
  newScreen(h, w, fd)

proc newRegion*(s: Screen, row, col, height, width: int): Region =
  if row < 0 or col < 0 or height <= 0 or width <= 0 or
     row + height > s.height or col + width > s.width:
    raise newException(ValueError,
      "region (" & $row & "," & $col & "," & $height & "x" & $width &
      ") out of screen bounds " & $s.height & "x" & $s.width)
  result = Region(screen: s, row: row, col: col,
                  height: height, width: width)
  s.regions.add result

proc set*(r: Region, content: openArray[string]) =
  ## Queue a new target. The flush after this call will emit only the
  ## rows that differ from what's currently on screen. Excess rows
  ## (content longer than `r.height`) are truncated, matching setRow's
  ## "never push past r.height" behavior so the two writers stay
  ## symmetric.
  if content.len <= r.height:
    r.target = @content
  else:
    r.target = @(content[0 ..< r.height])
  r.pending = true

proc markDirty*(r: Region) =
  ## Force `r` to be re-emitted on the next flush even if its target
  ## hasn't changed (e.g. after the renderer was invalidated externally).
  r.pending = true

proc setRow*(r: Region, idx: int, line: string) =
  ## Replace a single row in the region's target. Idx is region-local
  ## (0 == top of region). Out-of-bounds is silently dropped — the
  ## renderer's row clipping handles regions that have shrunk.
  if idx < 0 or idx >= r.height: return
  while r.target.len <= idx: r.target.add ""
  if r.target[idx] != line:
    r.target[idx] = line
    r.pending = true

proc flush*(s: Screen): string =
  ## Returns the ANSI bytes needed to bring the screen to the target
  ## state defined by all currently-pending regions. Idempotent: a
  ## second flush with no `set()` between them returns "".
  ##
  ## A region with `pendingScroll != 0` first emits a DECSTBM
  ## scroll command (and updates the renderer's cache accordingly)
  ## before the standard target diff. The intended use: tail-append
  ## in `bindCollection(mode = wmFromEnd)` — emits one scroll + one
  ## new-row paint instead of N row repaints.
  result = ""
  for r in s.regions:
    if r.pendingScroll != 0:
      result &= s.renderer.scrollUpRegion(
        r.row, r.row + r.height - 1, r.pendingScroll)
      r.pendingScroll = 0
    if not r.pending: continue
    result &= s.renderer.render(r.row, r.col, r.target)
    r.pending = false

proc scrollUp*(r: Region, n: int = 1) =
  ## Queue a scroll-up of this region by `n` lines. Takes effect on
  ## the next `flush()`. Used by tail-window bindings; not typically
  ## a direct caller concern.
  if n > 0: r.pendingScroll = n

proc paint*(s: Screen) =
  ## Convenience: flush + write the resulting bytes to `s.fd`. Most
  ## widgets call this after mutating their region's target; tests
  ## that want to inspect the rendered bytes call `flush()` instead.
  ##
  ## Handles partial writes and EINTR: a fully-flushed render is a
  ## correctness property (a partial write would tear an ANSI sequence
  ## mid-escape), so we loop until every byte is committed or an
  ## unrecoverable error surfaces — at which point the remainder is
  ## dropped silently. EAGAIN on a non-blocking stderr backs off via
  ## a single retry; persistent backpressure also drops the remainder.
  let bytes = s.flush()
  if bytes.len == 0: return
  var written = 0
  while written < bytes.len:
    let n = posix.write(s.fd, unsafeAddr bytes[written], bytes.len - written)
    if n > 0:
      written += n
    elif errno == EINTR:
      continue
    else:
      break   # EAGAIN / EBADF / EPIPE — caller will see truncation on next paint

# --- SIGWINCH -------------------------------------------------------------

var resizePending: bool
  ## Process-wide flag set by the SIGWINCH handler. Not exported as
  ## a mutable var — callers read it via `isResizePending()` and reset
  ## it by calling `resize()` (which clears the flag as part of its
  ## work). Unconditional write access from user code would let callers
  ## silently suppress a pending resize.

proc isResizePending*(): bool = resizePending
  ## Read-only check: returns true if a SIGWINCH arrived since the
  ## last `resize()` call. Use to drive a poll loop.

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
  ## Re-query terminal size, resize the renderer, and mark every
  ## region pending so the next flush repaints from a clean slate.
  ##
  ## Regions that no longer fit (their declared row+height extends past
  ## the new screen height, or col+width past the new width) are
  ## clamped in place so the renderer doesn't silently drop content
  ## without anyone noticing. Callers using a layout (vstack/hstack)
  ## should call `relayout()` after resize() to redistribute properly.
  let (h, w) = queryWinsize(s.fd)
  s.height = h
  s.width  = w
  s.renderer.resize(h, w)
  for r in s.regions:
    if r.row >= h:
      r.height = 0   # whole region off-screen
    elif r.row + r.height > h:
      r.height = h - r.row
    if r.col >= w:
      r.width = 0
    elif r.col + r.width > w:
      r.width = w - r.col
    # Trim any rows of the previous target that no longer fit. Without
    # this the next flush would emit rows past the new region bottom,
    # painting over whatever sits below (typically another region).
    if r.target.len > r.height:
      r.target.setLen(r.height)
    r.pending = true
  resizePending = false
