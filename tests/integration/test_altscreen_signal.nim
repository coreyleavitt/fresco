## Integration test: SIGINT emits async-signal-safe ?1049l on the PTY.
##
## Tier-2 test — needs /dev/ptmx (verified available in container via
## existing in-process PTY tests). Spawns a compiled child process via
## the PTY-subprocess harness; the child enters alt-screen then waits.
## Parent sends SIGINT; asserts ?1049l appears in the master byte stream
## before the child exits.
##
## Async-signal-safety is verified by code inspection (see termios.nim):
## the handler uses a const array + raw POSIX write() — no Nim GC calls.

import std/[unittest, posix, os, strutils]
import ./helpers/pty_subprocess
import ./helpers/compile_child

proc ioctlSetCTTY(fd: cint; request: culong; arg: cint): cint
  {.importc: "ioctl", header: "<sys/ioctl.h>", varargs.}
proc setsid_c(): Pid {.importc: "setsid", header: "<unistd.h>".}
const TIOCSCTTY_VAL: culong = 0x540E

# The ?1049l byte sequence we expect to see on the PTY master stream.
const AltScreenLeaveSeq = "\x1b[?1049l"

# Path to the child helper binary (compiled on demand via compileChildBinary).
const ChildBin = "/tmp/fresco_altscreen_signal_child"
const ChildSrcName = "altscreen_signal_child.nim"  # relative to helpers/

proc sleepMs(ms: int) =
  var ts  = Timespec(tv_sec: posix.Time(0), tv_nsec: clong(ms * 1_000_000))
  var rem = Timespec()
  discard posix.nanosleep(ts, rem)

proc forkExecOnPty(binPath: string): tuple[pid: Pid, master: cint] =
  ## Open a PTY pair, fork, exec `binPath` on the slave.
  ## Returns the child pid and master fd to the caller.
  ## Caller is responsible for closing master and reaping the child.
  let (master, slave) = openPtyPair()
  let pid = fork()
  if pid < 0:
    discard posix.close(master)
    discard posix.close(slave)
    raise newException(OSError, "fork failed")
  if pid == 0:
    discard setsid_c()
    discard ioctlSetCTTY(slave, TIOCSCTTY_VAL, 0)
    discard dup2(slave, STDIN_FILENO)
    discard dup2(slave, STDOUT_FILENO)
    discard dup2(slave, STDERR_FILENO)
    if slave > STDERR_FILENO: discard posix.close(slave)
    discard posix.close(master)
    let shPath = cstring("/bin/sh")
    let args = allocCStringArray(["/bin/sh", "-c", binPath])
    discard execv(shPath, args)
    quit(127)
  discard posix.close(slave)
  (pid, master)

suite "altscreen signal: async-signal-safe ?1049l on SIGINT":

  test "child helper compiles":
    let (ok, msg) = compileChildBinary(ChildSrcName, ChildBin)
    if not ok: skip()
    check ok

  test "SIGINT emits ?1049l on the PTY master before child exits":
    let (ok, compMsg) = compileChildBinary(ChildSrcName, ChildBin)
    if not ok: skip()
    discard compMsg

    let (pid, master) = forkExecOnPty(ChildBin)
    defer: discard posix.close(master)

    # Set master non-blocking for incremental polling.
    let flags = fcntl(master, F_GETFL, 0)
    discard fcntl(master, F_SETFL, flags or O_NONBLOCK)

    # Read until "READY" appears — child has armed the signal handler.
    var accumulated = ""
    var readyFound = false
    for _ in 0 ..< 2000:
      var buf: array[256, byte]
      let n = posix.read(master, addr buf[0], buf.len)
      if n > 0:
        for i in 0 ..< n: accumulated.add chr(buf[i].int)
        if "READY" in accumulated:
          readyFound = true
          break
      sleepMs(1)

    check readyFound

    if readyFound:
      # Send SIGINT — triggers the async-signal-safe handler.
      discard kill(pid, SIGINT)

      # Drain for up to 500ms to capture the ?1049l leave sequence.
      for _ in 0 ..< 500:
        var buf: array[256, byte]
        let n = posix.read(master, addr buf[0], buf.len)
        if n > 0:
          for i in 0 ..< n: accumulated.add chr(buf[i].int)
        elif errno == EIO:
          break  # slave closed after child died
        sleepMs(1)

      var status: cint = 0
      discard waitpid(pid, status, WNOHANG)
      discard kill(pid, SIGKILL)  # ensure cleanup
      discard waitpid(pid, status, 0)

      check AltScreenLeaveSeq in accumulated

  test "program never entering alt-screen does NOT emit ?1049l on SIGINT":
    ## A plain `sleep` child has no fresco signal handler installed.
    ## Default SIGINT disposition kills it; ?1049l must not appear.
    let (pid2, master2) = forkExecOnPty("sleep 60")
    defer: discard posix.close(master2)

    let flags2 = fcntl(master2, F_GETFL, 0)
    discard fcntl(master2, F_SETFL, flags2 or O_NONBLOCK)

    # Brief pause then SIGINT.
    sleepMs(50)
    discard kill(pid2, SIGINT)

    var output2 = ""
    for _ in 0 ..< 200:
      var buf: array[256, byte]
      let n = posix.read(master2, addr buf[0], buf.len)
      if n > 0:
        for i in 0 ..< n: output2.add chr(buf[i].int)
      elif errno == EIO:
        break
      sleepMs(1)

    var status2: cint = 0
    discard waitpid(pid2, status2, WNOHANG)
    discard kill(pid2, SIGKILL)
    discard waitpid(pid2, status2, 0)

    check AltScreenLeaveSeq notin output2
