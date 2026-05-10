import std/unittest
import std/posix
import fresco/terminal/termios

suite "termios against a non-TTY fd":

  test "saveTermios on /dev/null reports invalid":
    let fd = open(cstring("/dev/null"), O_RDWR)
    check fd >= 0
    defer: discard close(fd)
    let snap = saveTermios(fd)
    check snap.valid == false
    check snap.fd == fd

  test "restoreTermios on an invalid snapshot is a no-op (no crash)":
    var snap: TermiosSnapshot
    snap.valid = false
    restoreTermios(snap)
    check true

  test "enterCbreak on /dev/null leaves snapshot invalid":
    let fd = open(cstring("/dev/null"), O_RDWR)
    check fd >= 0
    defer: discard close(fd)
    let snap = enterCbreak(fd)
    check snap.valid == false
