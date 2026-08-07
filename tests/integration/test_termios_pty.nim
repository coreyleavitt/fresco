## Integration test: open a real PTY pair and verify that `enterCbreak`
## actually clears ICANON/ECHO/ISIG bits and that `restoreTermios` puts
## them back.

import std/unittest
import std/[posix, termios]
import fresco/terminal/termios
import ./helpers/pty_primitives

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
