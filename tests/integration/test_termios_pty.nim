## Integration test: open a real PTY pair and verify that `enterCbreak`
## actually clears ICANON/ECHO/ISIG bits and that `restoreTermios` puts
## them back.

import std/unittest
import std/[posix, termios]
import fresco/terminal/termios

proc posix_openpt(flags: cint): cint
  {.importc, header: "<stdlib.h>".}
proc grantpt(fd: cint): cint
  {.importc, header: "<stdlib.h>".}
proc unlockpt(fd: cint): cint
  {.importc, header: "<stdlib.h>".}
proc ptsname(fd: cint): cstring
  {.importc, header: "<stdlib.h>".}

proc openPtySlave(): cint =
  ## Allocate a PTY via POSIX primitives and return the slave fd.
  let master = posix_openpt(O_RDWR or O_NOCTTY)
  check master >= 0
  check grantpt(master) == 0
  check unlockpt(master) == 0
  let name = ptsname(master)
  check name != nil
  let slave = open(name, O_RDWR or O_NOCTTY)
  check slave >= 0
  return slave

proc bitsOf(fd: cint): Cflag =
  var t: Termios
  check tcGetAttr(fd, addr t) == 0
  return t.c_lflag

suite "termios against a real PTY":

  test "enterCbreak clears ICANON/ECHO/ISIG; restoreTermios reinstates them":
    let fd = openPtySlave()
    defer: discard close(fd)

    let before = bitsOf(fd)
    check (before and Cflag(ICANON)) != 0
    check (before and Cflag(ECHO))   != 0
    check (before and Cflag(ISIG))   != 0

    let snap = enterCbreak(fd)
    check snap.valid

    let raw = bitsOf(fd)
    check (raw and Cflag(ICANON)) == 0
    check (raw and Cflag(ECHO))   == 0
    check (raw and Cflag(ISIG))   == 0

    restoreTermios(snap)
    check bitsOf(fd) == before

  test "VMIN / VTIME set for one-byte reads in cbreak":
    let fd = openPtySlave()
    defer: discard close(fd)
    let snap = enterCbreak(fd)
    check snap.valid
    var t: Termios
    check tcGetAttr(fd, addr t) == 0
    check t.c_cc[VMIN]  == cchar(1)
    check t.c_cc[VTIME] == cchar(0)
    restoreTermios(snap)
