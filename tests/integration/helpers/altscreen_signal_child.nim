## Child helper for test_altscreen_signal.nim.
##
## This program:
##   1. Opens STDOUT_FILENO as the terminal fd.
##   2. Calls installSignalHandlers (for SIGINT/SIGTERM restore path).
##   3. Calls markAltScreenEntered to arm the async-signal-safe leave.
##   4. Writes ?1049h (enter alt screen) so the sequence appears on the PTY.
##   5. Writes a sentinel "READY\n" so the parent knows setup is done.
##   6. Sleeps in a loop — waits to be killed by SIGINT from the parent.
##
## On SIGINT the fresco signal handler fires:
##   - emits ?1049l via raw write (const buffer, no alloc) → visible on PTY
##   - restores termios (no-op if no cbreak snapshot)
##   - re-raises SIGINT with SIG_DFL → child exits
##
## The parent reads the PTY master and asserts ?1049l appears before exit.

import std/posix
import fresco/terminal/termios as termios_mod
import fresco/terminal/ansi

# A dummy snapshot — we're not entering cbreak in this helper; we just
# need the signal handler installed so its termios-restore + alt-screen
# leave path fires on SIGINT.
let snap = saveTermios(STDOUT_FILENO)
installSignalHandlers(snap)

# Arm the async-signal-safe alt-screen leave for STDOUT_FILENO.
markAltScreenEntered(STDOUT_FILENO)

# Write the enter sequence — not strictly required for the test assertion
# (the test only checks for the *leave*), but makes the lifecycle correct.
let enterSeq = altScreenEnter()
discard posix.write(STDOUT_FILENO, unsafeAddr enterSeq[0], enterSeq.len)

# Signal readiness to parent.
let ready = "READY\n"
discard posix.write(STDOUT_FILENO, unsafeAddr ready[0], ready.len)

# Spin-wait for signal. nanosleep keeps us from burning CPU; SIGINT will
# interrupt the syscall with EINTR, after which the signal handler runs,
# re-raises with SIG_DFL, and the process exits.
while true:
  var ts  = Timespec(tv_sec: posix.Time(1), tv_nsec: 0)
  var rem = Timespec()
  discard posix.nanosleep(ts, rem)
