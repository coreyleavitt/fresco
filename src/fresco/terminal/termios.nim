## Termios save/restore + cbreak helpers.
##
## Crash safety (DESIGN.md L6) rests on two guarantees:
##
##   1. `withCbreak` restores the saved termios on every exit path
##      including exceptions, via `try/finally`.
##   2. While inside `withCbreak`, SIGINT / SIGTERM / SIGSEGV handlers
##      are installed that restore termios *before* the signal is
##      re-raised with default disposition.
##
## Saving against a non-TTY fd (e.g. /dev/null) is not an error: the
## snapshot just carries `valid = false` and restore becomes a no-op.

import std/[posix, termios]

type
  TermiosSnapshot* = object
    fd*: cint
    saved*: Termios
    valid*: bool

proc saveTermios*(fd: cint = STDIN_FILENO): TermiosSnapshot =
  ## Snapshot the current termios for `fd`. Returns a snapshot whose
  ## `valid` field is false when `fd` is not a terminal.
  result.fd = fd
  result.valid = tcGetAttr(fd, addr result.saved) == 0

proc restoreTermios*(s: TermiosSnapshot) =
  ## No-op when `s.valid` is false (e.g. snapshot taken against a
  ## non-TTY fd). Uses TCSAFLUSH to discard any pending unread input.
  if s.valid:
    discard tcSetAttr(s.fd, TCSAFLUSH, addr s.saved)

proc enterCbreak*(fd: cint = STDIN_FILENO): TermiosSnapshot =
  ## Save current termios and switch `fd` into cbreak: ICANON, ECHO,
  ## and ISIG cleared on the local-mode side; IXON (XON/XOFF flow
  ## control, which would steal Ctrl-Q / Ctrl-S) cleared on the input
  ## side. One-byte reads (VMIN=1, VTIME=0). Returns the snapshot the
  ## caller (or `withCbreak`) restores from.
  result = saveTermios(fd)
  if not result.valid: return
  var raw = result.saved
  let lmask = not Cflag(ICANON or ECHO or ISIG)
  let imask = not Cflag(IXON)
  raw.c_lflag = raw.c_lflag and lmask
  raw.c_iflag = raw.c_iflag and imask
  raw.c_cc[VMIN] = cchar(1)
  raw.c_cc[VTIME] = cchar(0)
  discard tcSetAttr(fd, TCSAFLUSH, addr raw)

# --- signal-safe restore --------------------------------------------------

# Stack of snapshots so nested cbreak scopes (e.g. a confirm prompt
# inside an already-raw program) each get their *original* termios
# back if a signal fires before they cleanly exit. The fatal-signal
# handler walks the stack top-down restoring each saved state.

const MaxSignalSnapshots* {.intdefine.} = 16
  ## Bound on simultaneously-nested cbreak scopes the signal handler
  ## can restore. Configurable via `-d:MaxSignalSnapshots=N`. Past
  ## the bound, snapshots are silently not stored (depth counter
  ## keeps pairing correct). Deep nesting isn't a real workload —
  ## the bound exists to keep the handler signal-safe (no alloc).

# All state for the signal-handler stack lives in threadvars. fresco is
# single-thread by design (one chronos dispatcher per thread), so this
# is semantically equivalent to plain globals — but Nim's gcsafe
# inference treats threadvars as gcsafe, which lets install/uninstall
# (and therefore `stop()` in input.nim) be genuinely gcsafe without
# `{.cast(gcsafe).}` escape hatches at the call site.
#
# **Multi-thread caveat for embedders:** POSIX delivers fatal signals
# to *some* thread in the process, not necessarily the one that called
# `installSignalHandlers`. If embedded in a multi-threaded host and a
# signal arrives on a thread that never installed handlers, that
# thread's `snapshotStack` is empty and the handler skips termios
# restore — leaving the user's terminal in raw mode. Single-thread
# apps (fresco's design target) are unaffected. Proper multi-thread
# safety would require a shared restore stack with its own lock,
# which conflicts with the signal-safe (no-alloc) invariant.
var snapshotStack {.threadvar.}: array[MaxSignalSnapshots, TermiosSnapshot]
var snapshotDepth {.threadvar.}: int

type SigHandler = proc(sig: cint) {.noconv.}
var prevSigInt  {.threadvar.}: SigHandler
var prevSigTerm {.threadvar.}: SigHandler
var prevSigSegv {.threadvar.}: SigHandler

# --- async-signal-safe alt-screen leave -------------------------------------
#
# These threadvars mirror the termios-restore state above. They must be
# plain C-compatible types (cint / cint-as-bool) so the signal handler can
# read and write them without any Nim GC interaction.
#
# `sigAltScreenFd` holds the output fd to write the leave sequence on.
# It is set by `markAltScreenEntered` (called from AltScreen.enter) and
# cleared by `markAltScreenLeft` (called from AltScreen.leave / finally).
#
# `sigAltScreenActive` is a cint used as a boolean flag (0 = not entered,
# 1 = entered). The signal handler emits the leave sequence only when this
# is non-zero. Plain assignment is async-signal-safe on all targets.
var sigAltScreenFd     {.threadvar.}: cint   ## output fd, or -1 when none
var sigAltScreenActive {.threadvar.}: cint   ## 1 when alt-screen is live

# Compile-time constant byte buffer for `\x1b[?1049l` — no heap alloc.
# Using a `array[N, byte]` lets us pass `addr` directly to the POSIX
# write() syscall, which is on the async-signal-safe list (POSIX.1-2017).
const AltScreenLeaveBytes*: array[8, byte] =
  [0x1b'u8, 0x5b, 0x3f, 0x31, 0x30, 0x34, 0x39, 0x6c]
  # ESC  [    ?    1    0    4    9    l

proc markAltScreenEntered*(fd: cint) {.gcsafe, raises: [].} =
  ## Record that the alternate-screen buffer has been entered on `fd`.
  ## Called by AltScreen.enter AFTER the ?1049h write succeeds.
  ## Setting two plain cint threadvars is async-signal-safe by assignment.
  sigAltScreenFd     = fd
  sigAltScreenActive = 1

proc markAltScreenLeft*() {.gcsafe, raises: [].} =
  ## Clear the alt-screen signal state. Called by AltScreen.leave and
  ## by withAltScreen's finally block so normal exit doesn't double-emit.
  sigAltScreenActive = 0
  sigAltScreenFd     = -1

proc termiosSignalHandler(sig: cint) {.noconv.} =
  # Emit ?1049l FIRST (before termios restore) so the terminal returns to
  # the primary buffer before we hand control back to cooked mode. Only
  # emit when alt-screen was actually entered — the flag prevents the
  # sequence appearing for programs that never called enter().
  #
  # ASYNC-SIGNAL-SAFE: const array on the stack (no heap), raw POSIX
  # write() syscall, plain cint reads. No Nim GC calls anywhere in
  # this path.
  if sigAltScreenActive != 0 and sigAltScreenFd >= 0:
    # Stack-local copy of the const — no heap alloc.
    var buf = AltScreenLeaveBytes
    var remaining = buf.len
    var offset = 0
    while remaining > 0:
      let n = posix.write(sigAltScreenFd, addr buf[offset], remaining)
      if n > 0:
        offset += n
        remaining -= n
      elif errno == EINTR:
        continue
      else:
        break
    sigAltScreenActive = 0

  # Restore innermost-first: each stored scope undoes its own change
  # so the final state is the termios as of process startup. When
  # depth exceeded MaxSignalSnapshots, we restore from the first
  # `MaxSignalSnapshots` only — better than reading uninitialized
  # array slots, and the outermost original termios is always stored.
  let top = min(snapshotDepth, MaxSignalSnapshots) - 1
  for i in countdown(top, 0):
    restoreTermios(snapshotStack[i])
  signal(sig, SIG_DFL)
  discard kill(getpid(), sig)

proc installSignalHandlers*(s: TermiosSnapshot) {.gcsafe, raises: [].} =
  ## Register restore-on-fatal-signal hooks for SIGINT/SIGTERM/SIGSEGV.
  ## Nested install calls push onto a stack so the original termios
  ## of each scope is preserved through fatal-signal restore. Snapshots
  ## beyond MaxSignalSnapshots (16) are silently *not stored*, but the
  ## depth counter still increments — pairing with uninstall stays
  ## correct even at extreme nesting. Deep nesting is not a real
  ## workload; the bound exists to keep this signal-safe (no alloc).
  if snapshotDepth < MaxSignalSnapshots:
    snapshotStack[snapshotDepth] = s
  inc snapshotDepth
  if snapshotDepth == 1:
    # `signal()` returns the prior handler; capture so uninstall can
    # restore the caller's original disposition instead of SIG_DFL.
    prevSigInt  = cast[SigHandler](signal(SIGINT,  termiosSignalHandler))
    prevSigTerm = cast[SigHandler](signal(SIGTERM, termiosSignalHandler))
    prevSigSegv = cast[SigHandler](signal(SIGSEGV, termiosSignalHandler))

proc uninstallSignalHandlers*() {.gcsafe, raises: [].} =
  ## Pop one nest level; restore the caller's prior handlers (or
  ## SIG_DFL if none were installed before us) only when the stack
  ## is empty. Mirrors `installSignalHandlers` exactly so the pairing
  ## stays correct whether or not the corresponding install actually
  ## stored its snapshot in the bounded array.
  if snapshotDepth > 0: dec snapshotDepth
  if snapshotDepth == 0:
    discard signal(SIGINT,
      if prevSigInt  != nil: prevSigInt  else: SIG_DFL)
    discard signal(SIGTERM,
      if prevSigTerm != nil: prevSigTerm else: SIG_DFL)
    discard signal(SIGSEGV,
      if prevSigSegv != nil: prevSigSegv else: SIG_DFL)
    prevSigInt = nil; prevSigTerm = nil; prevSigSegv = nil

template withCbreak*(fd: cint, body: untyped) =
  let snap = enterCbreak(fd)
  installSignalHandlers(snap)
  try:
    body
  finally:
    uninstallSignalHandlers()
    restoreTermios(snap)

template withCbreak*(body: untyped) =
  withCbreak(STDIN_FILENO, body)
