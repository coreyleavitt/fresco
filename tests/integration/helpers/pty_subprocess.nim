## PTY-subprocess harness for tier-2 integration tests.
##
## `runInPty` forks a child process that runs `cmd` with the PTY slave as its
## controlling terminal + stdin/stdout/stderr, and returns all bytes read from
## the PTY master along with the child's exit code.
##
## Design:
##   - PTY pair opened with POSIX `posix_openpt` / `grantpt` / `unlockpt` —
##     the same pattern used by test_termios_pty.nim (in-process PTY tests).
##   - Parent drains the master in a non-blocking read loop with a timeout.
##   - Child is killed via SIGKILL after the timeout if still running.
##   - No async framework dependency — plain POSIX fork/exec/read/waitpid.
##
## The harness is tier-2 (needs /dev/ptmx in-container). Existing in-process
## PTY tests (test_termios_pty, test_input_pty) prove PTYs work in the
## container, so the open/setup path is always available.

import std/posix
import ./pty_primitives

# Custom ioctl with 3-arg form (for TIOCSCTTY). Nim's posix.ioctl only
# exposes the 2-arg variant; we need the full C signature here.
proc ioctlSetCTTY(fd: cint; request: culong; arg: cint): cint
  {.importc: "ioctl", header: "<sys/ioctl.h>", varargs.}

proc setsid_c(): Pid {.importc: "setsid", header: "<unistd.h>".}

const TIOCSCTTY_VAL: culong = 0x540E

proc openPtyPair*(): tuple[master, slave: cint] =
  ## Allocate a PTY and return both fds. Raises on failure. Delegates the
  ## open-a-PTY sequence to `pty_primitives.openPtyPairRaw` (shared with
  ## `openPtySlave` — see that proc's doc comment for why `O_RDWR` alone,
  ## without `O_NOCTTY`, is passed here) rather than hand-duplicating the
  ## five FFI calls.
  let (master, slave, err) = openPtyPairRaw(O_RDWR)
  if err.len > 0: raise newException(OSError, err)
  (master, slave)

# --- drain helper

proc drainMasterMs*(master: cint, timeoutMs: int): string =
  ## Read all available bytes from the master fd for up to `timeoutMs`
  ## milliseconds. Each iteration sleeps ~1ms; loop count = timeoutMs.
  ## Returns all accumulated bytes.
  let flags = fcntl(master, F_GETFL, 0)
  discard fcntl(master, F_SETFL, flags or O_NONBLOCK)
  var buf: array[4096, byte]
  result = ""
  for _ in 0 ..< timeoutMs:
    let n = posix.read(master, addr buf[0], buf.len)
    if n > 0:
      for i in 0 ..< n:
        result.add chr(buf[i].int)
    elif errno == EIO:
      break  # slave closed — child exited
    # sleep 1ms between polls
    var ts  = Timespec(tv_sec: posix.Time(0), tv_nsec: 1_000_000)
    var rem = Timespec()
    discard posix.nanosleep(ts, rem)

# --- runInPty

proc runInPty*(cmd: string, timeoutMs: int = 2000): tuple[output: string, exitCode: int] =
  ## Fork+exec `cmd` (via `/bin/sh -c`) with a fresh PTY as its controlling
  ## terminal. Parent drains the PTY master for `timeoutMs` milliseconds,
  ## then kills with SIGKILL if the child is still running.
  ##
  ## Returns all bytes read from the master and the child's exit code
  ## (or 128+signal if killed by a signal).
  let (master, slave) = openPtyPair()
  defer: discard close(master)

  let pid = fork()
  if pid < 0:
    discard close(slave)
    raise newException(OSError, "fork failed")

  if pid == 0:
    # child: become session leader, set controlling TTY, exec.
    discard setsid_c()
    discard ioctlSetCTTY(slave, TIOCSCTTY_VAL, 0)
    discard dup2(slave, STDIN_FILENO)
    discard dup2(slave, STDOUT_FILENO)
    discard dup2(slave, STDERR_FILENO)
    if slave > STDERR_FILENO: discard posix.close(slave)
    discard posix.close(master)
    let shPath = cstring("/bin/sh")
    let args = allocCStringArray(["/bin/sh", "-c", cmd])
    discard execv(shPath, args)
    quit(127)

  # parent
  discard posix.close(slave)

  result.output = drainMasterMs(master, timeoutMs)

  var status: cint = 0
  var waited = waitpid(pid, status, WNOHANG)
  if waited == 0:
    discard kill(pid, SIGKILL)
    waited = waitpid(pid, status, 0)

  if WIFEXITED(status):
    result.exitCode = WEXITSTATUS(status)
  elif WIFSIGNALED(status):
    result.exitCode = 128 + WTERMSIG(status)
  else:
    result.exitCode = -1
