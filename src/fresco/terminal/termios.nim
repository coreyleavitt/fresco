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
  ## and ISIG cleared; one-byte reads (VMIN=1, VTIME=0). Returns the
  ## snapshot the caller (or `withCbreak`) restores from.
  result = saveTermios(fd)
  if not result.valid: return
  var raw = result.saved
  let lmask = not Cflag(ICANON or ECHO or ISIG)
  raw.c_lflag = raw.c_lflag and lmask
  raw.c_cc[VMIN] = cchar(1)
  raw.c_cc[VTIME] = cchar(0)
  discard tcSetAttr(fd, TCSAFLUSH, addr raw)

# --- signal-safe restore --------------------------------------------------

var activeSnapshot: TermiosSnapshot
var snapshotActive: bool

proc termiosSignalHandler(sig: cint) {.noconv.} =
  if snapshotActive:
    restoreTermios(activeSnapshot)
  signal(sig, SIG_DFL)
  discard kill(getpid(), sig)

proc installSignalHandlers*(s: TermiosSnapshot) =
  ## Register restore-on-fatal-signal hooks for SIGINT/SIGTERM/SIGSEGV.
  activeSnapshot = s
  snapshotActive = true
  discard signal(SIGINT,  termiosSignalHandler)
  discard signal(SIGTERM, termiosSignalHandler)
  discard signal(SIGSEGV, termiosSignalHandler)

proc uninstallSignalHandlers*() =
  snapshotActive = false
  discard signal(SIGINT,  SIG_DFL)
  discard signal(SIGTERM, SIG_DFL)
  discard signal(SIGSEGV, SIG_DFL)

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
