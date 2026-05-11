## Integration test for the status widget.
##
## We can't verify "the status row survived 100 lines of streamed
## output" without a real terminal emulator (a raw PTY just passes
## bytes through). What we *can* verify is the bytes we emit:
##
##   - on creation: DECSTBM with the right scroll region
##   - on set + screen.flush: content placed at the bottom row
##   - on destroy: scroll region reset
##   - status row content cached: setting the same text twice emits
##     nothing the second time (the renderer's per-row diff holds)
##
## That covers the contract; the "100 lines don't clobber" behavior is
## a property of the terminal, not our code, given the DECSTBM is set.

import std/[unittest, strutils, posix, termios]
import fresco/screen
import fresco/terminal/ansi
import fresco/widgets/status

proc posix_openpt(flags: cint): cint {.importc, header: "<stdlib.h>".}
proc grantpt(fd: cint): cint           {.importc, header: "<stdlib.h>".}
proc unlockpt(fd: cint): cint          {.importc, header: "<stdlib.h>".}
proc ptsname(fd: cint): cstring        {.importc, header: "<stdlib.h>".}

proc openPtyPair(): tuple[master, slave: cint] =
  let master = posix_openpt(O_RDWR or O_NOCTTY)
  doAssert master >= 0
  doAssert grantpt(master) == 0
  doAssert unlockpt(master) == 0
  let slave = open(ptsname(master), O_RDWR or O_NOCTTY)
  doAssert slave >= 0
  return (master, slave)

proc readAvailable(fd: cint): string =
  ## Drain everything currently readable on `fd`. Non-blocking.
  var flags = fcntl(fd, F_GETFL, 0)
  discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)
  var buf: array[4096, char]
  while true:
    let n = posix.read(fd, addr buf[0], buf.len)
    if n <= 0: break
    let start = result.len
    result.setLen(start + n)
    for i in 0 ..< n: result[start + i] = buf[i]
  discard fcntl(fd, F_SETFL, flags)

suite "status widget":

  test "newStatus emits DECSTBM with correct scroll-region bounds":
    let (master, slave) = openPtyPair()
    defer:
      discard close(master); discard close(slave)
    let screen = newScreen(10, 40, slave)
    let status = newStatus(screen, height = 1)
    check status.region.row == 9
    check status.region.height == 1
    let emitted = readAvailable(master)
    # height=10, status=1 → scroll region rows 1..9.
    check setScrollRegion(1, 9) in emitted

  test "set + paint places content at the bottom row":
    let (master, slave) = openPtyPair()
    defer:
      discard close(master); discard close(slave)
    let screen = newScreen(10, 40, slave)
    let status = newStatus(screen, height = 1)
    discard readAvailable(master)  # drain init bytes
    status.set(["ready"])
    let bytes = screen.flush()
    # Row 9 (0-based) → CUP 10;1
    check cursorTo(10, 1) in bytes
    check "ready" in bytes

  test "setting the same content twice emits nothing the second time":
    let (master, slave) = openPtyPair()
    defer:
      discard close(master); discard close(slave)
    let screen = newScreen(10, 40, slave)
    let status = newStatus(screen)
    status.set(["hi"])
    discard screen.flush()
    status.set(["hi"])
    check screen.flush() == ""

  test "destroy emits scroll-region reset":
    let (master, slave) = openPtyPair()
    defer:
      discard close(master); discard close(slave)
    let screen = newScreen(10, 40, slave)
    let status = newStatus(screen)
    discard readAvailable(master)
    status.destroy()
    let emitted = readAvailable(master)
    check resetScrollRegion() in emitted

  test "multi-row status places content over the right rows":
    let (master, slave) = openPtyPair()
    defer:
      discard close(master); discard close(slave)
    let screen = newScreen(10, 40, slave)
    let status = newStatus(screen, height = 2)
    check status.region.row == 8
    status.set(["line A", "line B"])
    let bytes = screen.flush()
    check cursorTo(9, 1)  in bytes  # row index 8 (0-based) → 9 (1-based)
    check cursorTo(10, 1) in bytes
    check "line A" in bytes
    check "line B" in bytes
