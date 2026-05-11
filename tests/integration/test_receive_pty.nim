## Drive the `receive` macro through a real PTY pair.

import std/unittest
import std/[posix, termios, unicode]
import chronos
import fresco/input as fresco_input
import fresco/events
import fresco/task/receive

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

template rig(keys: string, body: untyped): string =
  ## Drive one receive arm: open PTY, write `keys` to master, then run
  ## the receive `body`, which writes into the injected `outcome`
  ## string. Returns `outcome`.
  block:
    proc inner(): Future[string] {.async: (raises: [Exception]).} =
      let (master, slave) = openPtyPair()
      let stream {.inject.} = newInputStream(slave)
      fresco_input.start(stream)
      defer:
        fresco_input.stop(stream)
        discard close(master)
        discard close(slave)

      var outcome {.inject.} = ""
      proc feeder() {.async: (raises: [Exception]).} =
        await sleepAsync(20.milliseconds)
        writeAll(master, keys)
      asyncSpawn feeder()
      body
      return outcome

    waitFor inner()

suite "receive: core patterns":

  test "Char literal pattern matches":
    let got = rig("+"):
      receive stream:
        Char('+'): outcome = "plus"
        Char('-'): outcome = "minus"
        _:         outcome = "other"
    check got == "plus"

  test "Char capture binds the rune":
    let got = rig("Q"):
      receive stream:
        Char(c): outcome = "char:" & $c
        _:       outcome = "other"
    check got == "char:Q"

  test "Ctrl literal pattern matches":
    let got = rig("\x03"):
      receive stream:
        Ctrl('c'): outcome = "quit"
        _:         outcome = "other"
    check got == "quit"

  test "Ctrl capture binds the letter":
    let got = rig("\x17"):
      receive stream:
        Ctrl(c): outcome = "ctrl:" & $c
        _:       outcome = "other"
    check got == "ctrl:w"

  test "Alt capture binds the letter":
    let got = rig("\x1ba"):
      receive stream:
        Alt(c): outcome = "alt:" & $c
        _:      outcome = "other"
    check got == "alt:a"

  test "Enter atom pattern matches":
    let got = rig("\r"):
      receive stream:
        Enter: outcome = "submit"
        _:     outcome = "other"
    check got == "submit"

  test "Backspace atom":
    let got = rig("\x7F"):
      receive stream:
        Backspace: outcome = "bs"
        _:         outcome = "other"
    check got == "bs"

  test "Arrow atoms":
    let got = rig("\x1b[A"):
      receive stream:
        ArrowUp:    outcome = "up"
        ArrowDown:  outcome = "down"
        ArrowLeft:  outcome = "left"
        ArrowRight: outcome = "right"
        _:          outcome = "other"
    check got == "up"

  test "F-key atom":
    let got = rig("\x1bOP"):
      receive stream:
        F1:        outcome = "help"
        F12:       outcome = "save"
        _:         outcome = "other"
    check got == "help"

  test "wildcard catches everything not enumerated":
    let got = rig("z"):
      receive stream:
        Char('a'): outcome = "a"
        Char('b'): outcome = "b"
        _:         outcome = "other"
    check got == "other"

  test "no wildcard, no matching arm: silently drops, outcome unset":
    let got = rig("z"):
      receive stream:
        Char('a'): outcome = "a"
        Enter:     outcome = "enter"
    check got == ""

  test "wildcard at end of body catches non-enumerated keys":
    # Regression: previous implementation pulled the wildcard out of
    # source order and put it as the final `else`, which meant arms
    # *after* a wildcard would fire BEFORE the wildcard. Now arms
    # after `_:` are warned as unreachable; arms before fire in order.
    let got = rig("z"):
      receive stream:
        Char('a'): outcome = "a"
        Char('b'): outcome = "b"
        _:         outcome = "fallback"
    check got == "fallback"

    let got2 = rig("a"):
      receive stream:
        Char('a'): outcome = "a"
        Char('b'): outcome = "b"
        _:         outcome = "fallback"
    check got2 == "a"

  test "specific Char before general Char(c) priorities by source order":
    let got = rig("a"):
      receive stream:
        Char('a'): outcome = "literal-a"
        Char(c):   outcome = "fallback-" & $c
    check got == "literal-a"

    let got2 = rig("b"):
      receive stream:
        Char('a'): outcome = "literal-a"
        Char(c):   outcome = "fallback-" & $c
    check got2 == "fallback-b"

suite "receive: after timeout":

  test "after fires when no key arrives in time":
    proc inner(): Future[string] {.async: (raises: [Exception]).} =
      let (master, slave) = openPtyPair()
      let stream = newInputStream(slave)
      fresco_input.start(stream)
      defer:
        fresco_input.stop(stream)
        discard close(master); discard close(slave)
      var outcome = "unset"
      receive stream:
        Char(c): outcome = "char:" & $c
        after 50.milliseconds: outcome = "timeout"
      return outcome
    check waitFor(inner()) == "timeout"

  test "key arm wins when input precedes the timeout":
    let got = rig("z"):
      receive stream:
        Char(c):                 outcome = "char:" & $c
        after 500.milliseconds:  outcome = "timeout"
    check got == "char:z"
