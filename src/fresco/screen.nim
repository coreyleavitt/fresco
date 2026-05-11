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
  ## rows that differ from what's currently on screen.
  r.target = @content
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
  result = ""
  for r in s.regions:
    if not r.pending: continue
    result &= s.renderer.render(r.row, r.col, r.target)
    r.pending = false

proc paint*(s: Screen) =
  ## Convenience: flush + write the resulting bytes to `s.fd`. Most
  ## widgets call this after mutating their region's target; tests
  ## that want to inspect the rendered bytes call `flush()` instead.
  let bytes = s.flush()
  if bytes.len > 0:
    discard posix.write(s.fd, unsafeAddr bytes[0], bytes.len)

# --- SIGWINCH -------------------------------------------------------------

var resizePending*: bool

proc winchHandler(sig: cint) {.noconv.} =
  resizePending = true

proc installResizeHandler*() =
  ## Installs a SIGWINCH handler that sets `resizePending`. Callers
  ## poll the flag (e.g. once per event-loop tick) and call `resize()`
  ## when it's true; signal handlers can't safely mutate Nim seqs.
  discard signal(SIGWINCH, winchHandler)

proc uninstallResizeHandler*() =
  discard signal(SIGWINCH, SIG_DFL)
  resizePending = false

proc resize*(s: Screen) =
  ## Re-query terminal size, resize the renderer, and mark every
  ## region pending so the next flush repaints from a clean slate.
  let (h, w) = queryWinsize(s.fd)
  s.height = h
  s.width  = w
  s.renderer.resize(h, w)
  for r in s.regions:
    r.pending = true
  resizePending = false
