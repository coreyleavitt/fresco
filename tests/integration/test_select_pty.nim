## Integration test: drive the select widget through a PTY pair.
##
## We open a PTY, attach an InputStream on the slave for reading keys,
## a Screen on the same slave for emitting ANSI (the test doesn't care
## what gets painted, only that the outcome matches the keys sent on
## the master).

import std/unittest
import std/[posix, termios]
import chronos
import fresco/input as fresco_input
import fresco/events
import fresco/screen
import fresco/widgets/select

proc posix_openpt(flags: cint): cint {.importc, header: "<stdlib.h>".}
proc grantpt(fd: cint): cint           {.importc, header: "<stdlib.h>".}
proc unlockpt(fd: cint): cint          {.importc, header: "<stdlib.h>".}
proc ptsname(fd: cint): cstring        {.importc, header: "<stdlib.h>".}

proc openPtyPair(): tuple[master, slave: cint] =
  let master = posix_openpt(O_RDWR or O_NOCTTY)
  doAssert master >= 0
  doAssert grantpt(master) == 0
  doAssert unlockpt(master) == 0
  let slave = open(ptsname(master), O_RDWR or O_NOCTTY)
  doAssert slave >= 0
  return (master, slave)

proc writeAll(fd: cint, s: string) =
  if s.len == 0: return
  let n = posix.write(fd, unsafeAddr s[0], s.len)
  doAssert n == s.len

proc drive(stream: InputStream, screen: Screen, region: Region,
           master: cint, keys: string): Future[SelectOutcome]
           {.async: (raises: [Exception]).} =
  proc feeder() {.async: (raises: [Exception]).} =
    await sleepAsync(20.milliseconds)
    writeAll(master, keys)
  asyncSpawn feeder()
  return await selectMenu(stream, screen, region,
                          @["alpha", "beta", "gamma"])

proc runSelect(keys: string): SelectOutcome =
  let (master, slave) = openPtyPair()
  let stream = newInputStream(slave)
  fresco_input.start(stream)
  let screen = newScreen(10, 40, slave)
  let region = newRegion(screen, 0, 0, 5, 40)
  try:
    result = waitFor drive(stream, screen, region, master, keys)
  finally:
    fresco_input.stop(stream)
    discard close(master)
    discard close(slave)

suite "select widget over PTY":

  test "Enter on default selection picks index 0":
    let outcome = runSelect("\r")
    check outcome.kind == soChosen
    check outcome.index == 0

  test "ArrowDown then Enter picks index 1":
    let outcome = runSelect("\x1b[B\r")
    check outcome.kind == soChosen
    check outcome.index == 1

  test "j j then Enter picks index 2":
    let outcome = runSelect("jj\r")
    check outcome.kind == soChosen
    check outcome.index == 2

  test "k after wrap-stop stays at 0":
    let outcome = runSelect("kk\r")
    check outcome.kind == soChosen
    check outcome.index == 0

  test "number key 3 picks index 2 directly":
    let outcome = runSelect("3")
    check outcome.kind == soChosen
    check outcome.index == 2

  test "Ctrl-C cancels":
    let outcome = runSelect("\x03")
    check outcome.kind == soCancelled

  test "Esc cancels (after ESC-timeout flush)":
    let outcome = runSelect("\x1b")
    check outcome.kind == soCancelled

  test "slash-command: typed command returned on Enter":
    let outcome = runSelect("/help\r")
    check outcome.kind == soSlashCommand
    check outcome.command == "help"

  test "slash-command Esc returns to menu":
    # After ESC, slashMode exits, selection still on 0; Enter picks it.
    let outcome = runSelect("/abc\x1b\r")
    check outcome.kind == soChosen
    check outcome.index == 0
