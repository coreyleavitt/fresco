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
var snapshotStack {.threadvar.}: array[MaxSignalSnapshots, TermiosSnapshot]
var snapshotDepth {.threadvar.}: int

type SigHandler = proc(sig: cint) {.noconv.}
var prevSigInt  {.threadvar.}: SigHandler
var prevSigTerm {.threadvar.}: SigHandler
var prevSigSegv {.threadvar.}: SigHandler

proc termiosSignalHandler(sig: cint) {.noconv.} =
  # Restore innermost-first: each stored scope undoes its own change
  # so the final state is the termios as of process startup. When
  # depth exceeded MaxSignalSnapshots, we restore from the first 16
  # only — better than reading uninitialized array slots, and the
  # outermost original termios is always stored.
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
