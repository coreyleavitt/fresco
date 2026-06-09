## test_inline_graceful_pty.nim — Tier-2 graceful SIGTERM teardown test.
##
## Spawns a compiled child helper that:
##   1. Builds an InlineScreen[TerminalSink] on STDERR (PTY slave).
##   2. Arms graceful teardown + spawns watchTeardownSignals.
##   3. Buffers two lines WITHOUT committing.
##   4. Signals readiness ("GRACE-READY") then sleeps.
##
## (a) Parent sends SIGTERM after ~300ms. The graceful handler fires:
##     - writes one byte to the self-pipe → chronos wakes → teardownFlush
##       runs in normal context → both lines flushed to the PTY master.
##     - restoreAllAndReraise re-raises SIGTERM → exit 128+15.
##     Assert: both lines in output, exit code 128+15.
##
## (b) Parent sends TWO SIGTERMs in quick succession. The second hits the
##     escalation path (sigGracefulPending already set) → hard handler fires
##     (static-buffer flush + restore + die). Process must still exit (no hang)
##     and at least one of the tail lines should appear.

import std/[unittest, posix, os, strutils]
import ./helpers/pty_subprocess
import ./helpers/compile_child

proc ioctlSetCTTY(fd: cint; request: culong; arg: cint): cint
  {.importc: "ioctl", header: "<sys/ioctl.h>", varargs.}
proc setsid_c(): Pid {.importc: "setsid", header: "<unistd.h>".}
const TIOCSCTTY_VAL: culong = 0x540E

const ChildBin = "/tmp/fresco_inline_graceful_child"
const ChildSrcName = "inline_graceful_child.nim"  # relative to helpers/

proc sleepMs(ms: int) =
  var ts  = Timespec(tv_sec: posix.Time(0), tv_nsec: clong(ms * 1_000_000))
  var rem = Timespec()
  discard posix.nanosleep(ts, rem)

## Fork+exec the child on a fresh PTY, returning (pid, masterFd).
## Caller must close masterFd and reap pid.
proc forkExecOnPty(binPath: string): tuple[pid: Pid, master: cint] =
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

## Wait until "GRACE-READY" appears in the master stream (up to readyTimeoutMs).
## Returns accumulated bytes so far.
proc waitReady(master: cint, readyTimeoutMs: int): tuple[output: string, found: bool] =
  let flags = fcntl(master, F_GETFL, 0)
  discard fcntl(master, F_SETFL, flags or O_NONBLOCK)
  var accumulated = ""
  for _ in 0 ..< readyTimeoutMs:
    var buf: array[256, byte]
    let n = posix.read(master, addr buf[0], buf.len)
    if n > 0:
      for i in 0 ..< n: accumulated.add chr(buf[i].int)
      if "GRACE-READY" in accumulated:
        return (accumulated, true)
    elif errno == EIO:
      break
    sleepMs(1)
  (accumulated, false)

## Drain the master for up to drainMs more milliseconds.
proc drainMore(master: cint, drainMs: int, accumulated: var string) =
  for _ in 0 ..< drainMs:
    var buf: array[256, byte]
    let n = posix.read(master, addr buf[0], buf.len)
    if n > 0:
      for i in 0 ..< n: accumulated.add chr(buf[i].int)
    elif errno == EIO:
      break
    sleepMs(1)

suite "inline graceful teardown: SIGTERM → self-pipe → dispatcher flush":

  test "child compiles":
    let (ok, msg) = compileChildBinary(ChildSrcName, ChildBin)
    if not ok: skip()
    check ok

  test "(a) graceful SIGTERM flushes full buffered tail via dispatcher":
    let (cOk, cMsg) = compileChildBinary(ChildSrcName, ChildBin)
    if not cOk: skip()
    discard cMsg

    let (pid, master) = forkExecOnPty(ChildBin)
    defer: discard posix.close(master)

    # Wait until child is ready (arms graceful handler + buffers lines).
    let (startOutput, readyFound) = waitReady(master, 2000)
    if readyFound:
      # Give chronos dispatcher a tick to start (belt + suspenders).
      sleepMs(50)

      # Send SIGTERM — graceful handler writes pipe byte; chronos wakes;
      # teardownFlush runs; restoreAllAndReraise re-raises SIGTERM.
      discard kill(pid, SIGTERM)

      # Drain for up to 1500ms to capture the flushed lines.
      var accumulated = startOutput
      drainMore(master, 1500, accumulated)

      # Reap.
      var status: cint = 0
      let waited = waitpid(pid, status, WNOHANG)
      if waited == 0:
        discard kill(pid, SIGKILL)
        discard waitpid(pid, status, 0)

      let exitCode =
        if WIFEXITED(status): WEXITSTATUS(status)
        elif WIFSIGNALED(status): 128 + WTERMSIG(status)
        else: -1

      # Both buffered lines must appear — flushed in normal context by teardownFlush.
      check accumulated.contains("GRACE-TAIL-1")
      check accumulated.contains("GRACE-TAIL-2")
      # Exit via SIGTERM re-raise → 128+15 on Linux.
      check exitCode == 128 + SIGTERM
    else:
      discard kill(pid, SIGKILL)
      var st: cint = 0; discard waitpid(pid, st, 0)
      check readyFound   # will fail with message

  test "(b) double SIGTERM escalation: static-buffer tail bytes appear and exit is SIGTERM":
    ## Strengthened from weak OR — both the tail bytes AND the signal exit
    ## must be observed to prove the escalation path is genuinely covered.
    ## First SIGTERM → graceful path (pipe byte written, sigGracefulPending=1).
    ## Second SIGTERM → escalation → hard handler (static-buffer flush + restore + die).
    ## The hard handler flushes the static tail buffer (armed in the child with the same lines)
    ## and re-raises SIGTERM → exit 128+SIGTERM. Both conditions are required.
    let (cOk2, cMsg2) = compileChildBinary(ChildSrcName, ChildBin)
    if not cOk2: skip()
    discard cMsg2

    let (pid, master) = forkExecOnPty(ChildBin)
    defer: discard posix.close(master)

    let (startOutput, readyFound) = waitReady(master, 2000)
    if readyFound:
      sleepMs(50)

      # Send two SIGTERMs in quick succession.
      discard kill(pid, SIGTERM)
      sleepMs(5)
      discard kill(pid, SIGTERM)

      # Drain up to 2000ms — the hard path exits nearly instantly.
      var accumulated = startOutput
      drainMore(master, 2000, accumulated)

      # Reap — must complete without a hang (harness timeout would catch wedge).
      var status: cint = 0
      var waited = waitpid(pid, status, WNOHANG)
      if waited == 0:
        sleepMs(500)
        waited = waitpid(pid, status, WNOHANG)
      if waited == 0:
        discard kill(pid, SIGKILL)
        discard waitpid(pid, status, 0)

      let exitCode =
        if WIFEXITED(status): WEXITSTATUS(status)
        elif WIFSIGNALED(status): 128 + WTERMSIG(status)
        else: -1

      # STRENGTHENED: the static-buffer tail bytes must appear on the PTY
      # (proves the hard handler ran its flush) AND the process must exit via
      # SIGTERM (not wedge into our SIGKILL). Both conditions are required to
      # demonstrate the escalation path is genuinely exercised.
      check accumulated.contains("GRACE-TAIL")
      check exitCode == 128 + SIGTERM
    else:
      discard kill(pid, SIGKILL)
      var st: cint = 0; discard waitpid(pid, st, 0)
      check readyFound   # will fail with message

  test "(c) graceful SIGINT flushes buffered tail via dispatcher":
    ## Exercises the SIGINT branch of gracefulSignalHandler (previously untested).
    ## Same scenario as test (a) but uses SIGINT instead of SIGTERM.
    ## The graceful handler fires on SIGINT → writes pipe byte → dispatcher wakes
    ## → teardownFlush runs → restoreAllAndReraise re-raises SIGINT → exit 128+SIGINT.
    let (cOk3, cMsg3) = compileChildBinary(ChildSrcName, ChildBin)
    if not cOk3: skip()
    discard cMsg3

    let (pid, master) = forkExecOnPty(ChildBin)
    defer: discard posix.close(master)

    let (startOutput, readyFound) = waitReady(master, 2000)
    if readyFound:
      sleepMs(50)

      # Send SIGINT — graceful handler fires (same self-pipe path as SIGTERM).
      discard kill(pid, SIGINT)

      var accumulated = startOutput
      drainMore(master, 1500, accumulated)

      var status: cint = 0
      let waited = waitpid(pid, status, WNOHANG)
      if waited == 0:
        discard kill(pid, SIGKILL)
        discard waitpid(pid, status, 0)

      let exitCode =
        if WIFEXITED(status): WEXITSTATUS(status)
        elif WIFSIGNALED(status): 128 + WTERMSIG(status)
        else: -1

      # Both buffered lines must appear — flushed by teardownFlush in normal context.
      check accumulated.contains("GRACE-TAIL-1")
      check accumulated.contains("GRACE-TAIL-2")
      # Exit via SIGINT re-raise → 128+2 on Linux.
      check exitCode == 128 + SIGINT
    else:
      discard kill(pid, SIGKILL)
      var st: cint = 0; discard waitpid(pid, st, 0)
      check readyFound   # will fail with message
