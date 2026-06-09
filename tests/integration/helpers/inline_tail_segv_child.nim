## Child helper for test_inline_tail_pty.nim.
##
## This program:
##   1. Sets up the static tail buffer on STDERR_FILENO.
##   2. Arms the tail buffer with two known lines.
##   3. Installs fresco signal handlers so termiosSignalHandler fires on SIGSEGV.
##   4. Disables ONLCR on STDERR so \n is not translated to \r\n on the PTY.
##   5. Triggers a genuine SIGSEGV (null dereference).
##
## The crash handler fires:
##   - flushes sigTailBuf via raw write to STDERR
##   - restores termios (no-op since we didn't enter cbreak)
##   - re-raises SIGSEGV with SIG_DFL → child exits with signal

import std/posix
import std/termios as stdTermios
import fresco/terminal/termios as termiosMod

# Suppress ONLCR translation on STDERR so the flush bytes land verbatim
# on the PTY master (no \r injected before each \n).
var t: stdTermios.Termios
if tcGetAttr(STDERR_FILENO, addr t) == 0:
  t.c_oflag = t.c_oflag and not Cflag(ONLCR)
  discard tcSetAttr(STDERR_FILENO, TCSAFLUSH, addr t)

# Arm and populate the tail buffer on STDERR.
let snap = termiosMod.saveTermios(STDERR_FILENO)
termiosMod.installSignalHandlers(snap)
termiosMod.armInlineTail(STDERR_FILENO)
termiosMod.setInlineTail(["SEGV-TAIL-A", "SEGV-TAIL-B"])

# Signal readiness to parent.
let ready = "READY\n"
discard posix.write(STDERR_FILENO, unsafeAddr ready[0], ready.len)

# Trigger a genuine SIGSEGV. The crash handler flushes the tail to STDERR.
var p: ptr int = nil
p[] = 0
