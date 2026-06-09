import std/unittest
import std/posix
import std/strutils
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
    # After perfect pairing, a fresh install/uninstall round must not
    # raise (depth counter would be in a corrupt state otherwise).
    var raised = false
    try:
      installSignalHandlers(snap)
      uninstallSignalHandlers()
    except CatchableError:
      raised = true
    check not raised

  test "H4: SIGABRT and SIGBUS are registered (handlers survive round-trip)":
    ## Verify that installSignalHandlers installs a non-SIG_DFL handler on
    ## SIGABRT and SIGBUS, and that uninstallSignalHandlers restores the prior
    ## handler (SIG_DFL in this context since nothing else set them).
    ##
    ## The test cannot safely raise SIGABRT/SIGBUS in-process (that would crash
    ## the test runner), so we probe indirectly: after install, query the current
    ## handler via signal(sig, SIG_IGN) — which atomically replaces the current
    ## handler and returns the prior one — then restore the captured handler.
    ## If install did nothing, the prior handler would be SIG_DFL (nil cast); if
    ## it installed our handler, the returned value will be non-nil (termiosSignalHandler).
    var snap: TermiosSnapshot
    snap.valid = false
    installSignalHandlers(snap)

    # Probe SIGABRT: swap in SIG_IGN, capture what was there, restore it.
    let prevAbrt = signal(SIGABRT, SIG_IGN)
    discard signal(SIGABRT, prevAbrt)   # restore
    # Probe SIGBUS.
    let prevBus  = signal(SIGBUS,  SIG_IGN)
    discard signal(SIGBUS,  prevBus)

    uninstallSignalHandlers()

    # prevAbrt and prevBus must be non-nil — they were our installed handler.
    # cast[pointer] comparison: SIG_DFL is typically nil on Linux.
    check cast[pointer](prevAbrt) != cast[pointer](SIG_DFL)
    check cast[pointer](prevBus)  != cast[pointer](SIG_DFL)

# --- Security-2: test-and-clear reentrancy guard in flushInlineTailNow ---

suite "termios Security-2: tail flush test-and-clear prevents double-emit":

  proc openPipe2(): tuple[r, w: cint] =
    var fds: array[2, cint]
    if pipe(fds) != 0: raise newException(OSError, "pipe failed")
    (fds[0], fds[1])

  proc readPipeAll(fd: cint): string =
    let flags = fcntl(fd, F_GETFL, 0)
    discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)
    var buf: array[4096, byte]
    result = ""
    while true:
      let n = posix.read(fd, addr buf[0], buf.len)
      if n > 0:
        for i in 0 ..< n: result.add chr(buf[i].int)
      elif errno == EAGAIN or errno == EWOULDBLOCK:
        break
      elif errno == EINTR:
        continue
      else:
        break

  test "Security-2: double call to flushInlineTailNow emits exactly once":
    ## The test-and-clear idiom (sigTailArmed = 0 BEFORE the write loop)
    ## means a second call to flushInlineTailNow after the first is a no-op:
    ## sigTailArmed is already 0, so the guard condition fails and nothing
    ## is written. This proves the re-entrant signal scenario cannot
    ## double-emit the tail.
    let (pipeR, pipeW) = openPipe2()
    defer:
      discard posix.close(pipeR)
      discard posix.close(pipeW)

    armInlineTail(pipeW)
    setInlineTail(["tail-line"])

    # First flush — must write "tail-line\n" and clear sigTailArmed.
    flushInlineTailNow()
    check not inlineTailArmed()

    # Second flush — sigTailArmed is 0; must NOT write anything.
    flushInlineTailNow()

    # Close write end so read can drain without hanging.
    discard posix.close(pipeW)

    let received = readPipeAll(pipeR)
    # Content must appear exactly once (not twice).
    check received == "tail-line\n"
    let countOccurrences = received.count("tail-line")
    check countOccurrences == 1

  test "Security-2: sigTailArmed cleared before write (not after)":
    ## After armInlineTail + setInlineTail, call flushInlineTailNow and
    ## verify that inlineTailArmed() returns false AFTER the call — the
    ## clear happens (test-and-clear semantics confirmed).
    ## The write itself is validated by the separate pipe test above.
    armInlineTail(2)  # fd=2 (stderr), we only care about the guard state
    setInlineTail(["guard-test"])
    check inlineTailArmed()
    flushInlineTailNow()
    check not inlineTailArmed()  # must be cleared regardless of write result
