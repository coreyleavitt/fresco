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

proc openPtySlave*(): cint =
  ## Allocate a PTY via POSIX primitives and return the slave fd only
  ## (the master fd is intentionally left open — every call site this
  ## replaces ran in a short-lived test binary and never reclaimed it).
  let master = posix_openpt(O_RDWR or O_NOCTTY)
  doAssert master >= 0
  doAssert grantpt(master) == 0
  doAssert unlockpt(master) == 0
  let name = ptsname(master)
  doAssert name != nil
  let slave = posix.open(name, O_RDWR or O_NOCTTY)
  doAssert slave >= 0
  slave
