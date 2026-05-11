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

  test "install/uninstall stay paired past MaxSignalSnapshots":
    # Regression: a 17th+ nested install used to skip the push without
    # tracking it; uninstall always decremented, mis-pairing depth and
    # causing the signal handler to walk corrupted state. With the fix
    # the depth counter tracks every level even when the bounded array
    # can't store the snapshot.
    var snap: TermiosSnapshot
    snap.valid = false
    const N = 20  # well past the bound of 16
    for _ in 0 ..< N:
      installSignalHandlers(snap)
    for _ in 0 ..< N:
      uninstallSignalHandlers()
    # If pairing were off, this last install would re-trigger the
    # depth-1 branch incorrectly or skip it. We exercise that path:
    installSignalHandlers(snap)
    uninstallSignalHandlers()
    check true
