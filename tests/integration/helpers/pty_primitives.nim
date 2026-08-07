## Shared PTY-allocation FFI for tier-2 integration tests.
##
## `posix_openpt`/`grantpt`/`unlockpt`/`ptsname`/`openPtySlave` were
## previously declared independently in three places: test_termios_pty.nim,
## helpers/pty_subprocess.nim (which even said "same declarations as
## test_termios_pty"), and — before it moved to tests/integration/ — the
## R3-2 PTY suite in tests/unit/test_inline_lifecycle.nim. One declaration
## site now; every PTY-opening test imports this module directly or
## transitively via pty_subprocess.nim's `openPtyPair`.

import std/posix

proc posix_openpt*(flags: cint): cint {.importc, header: "<stdlib.h>".}
proc grantpt*(fd: cint): cint         {.importc, header: "<stdlib.h>".}
proc unlockpt*(fd: cint): cint        {.importc, header: "<stdlib.h>".}
proc ptsname*(fd: cint): cstring      {.importc, header: "<stdlib.h>".}

proc openPtyPairRaw*(slaveFlags: cint = O_RDWR or O_NOCTTY):
    tuple[master, slave: cint, err: string] =
  ## The open-a-PTY sequence — posix_openpt -> grantpt -> unlockpt ->
  ## ptsname -> open(slave, slaveFlags) — factored out so `openPtySlave`
  ## (below) and `pty_subprocess.openPtyPair` no longer hand-duplicate the
  ## five FFI calls (each previously repeated them with its own error
  ## handling).
  ##
  ## `slaveFlags` defaults to `O_RDWR or O_NOCTTY`, this module's own
  ## `openPtySlave` contract, which must not accidentally acquire the
  ## slave as this process's controlling terminal. `pty_subprocess.
  ## openPtyPair` passes `O_RDWR` alone — the one real difference between
  ## the two previously-hand-duplicated sequences, so it stays a caller
  ## choice rather than being silently unified: its forked child sets the
  ## controlling terminal explicitly via `TIOCSCTTY` after `fork`, so the
  ## parent-side open there never depended on `O_NOCTTY`.
  ##
  ## Returns fds as the POSIX calls leave them; `err` names the failing
  ## step (`""` on success). Callers apply their own failure semantics on
  ## top of `err` — `openPtySlave` doAsserts, `openPtyPair` raises
  ## `OSError` — rather than this proc picking one for both.
  let master = posix_openpt(O_RDWR or O_NOCTTY)
  if master < 0:
    return (master, cint(-1), "posix_openpt failed")
  if grantpt(master) != 0:
    return (master, cint(-1), "grantpt failed")
  if unlockpt(master) != 0:
    return (master, cint(-1), "unlockpt failed")
  let name = ptsname(master)
  if name == nil:
    return (master, cint(-1), "ptsname returned nil")
  let slave = posix.open(name, slaveFlags)
  if slave < 0:
    return (master, slave, "open slave PTY failed")
  (master, slave, "")

proc openPtySlave*(): cint =
  ## Allocate a PTY via POSIX primitives and return the slave fd only
  ## (the master fd is intentionally left open — every call site this
  ## replaces ran in a short-lived test binary and never reclaimed it).
  let (_, slave, err) = openPtyPairRaw()
  doAssert err.len == 0, err
  slave
