## Hotkey integration tests over a real PTY pair.

import std/unittest
import std/[posix, termios]
import chronos
import fresco/events
import fresco/input as fresco_input
import fresco/reactive/scope
import fresco/task/hotkey

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

template withRig(setupBody, runBody: untyped) {.dirty.} =
  proc rigBody() {.async: (raises: [Exception]).} =
    let (master {.inject.}, slave) = openPtyPair()
    let stream {.inject.} = newInputStream(slave)
    fresco_input.start(stream)
    defer:
      fresco_input.stop(stream)
      discard close(master)
      discard close(slave)
    let scope {.inject.} = newScope()
    withScope(scope):
      setupBody
    runBody
    dispose(scope)
  waitFor rigBody()

suite "hotkey":

  test "fires on matching key; consumes the event (not delivered to nextKey)":
    var fired = false
    withRig:
      hotkey stream, ctrlKey('q'):
        fired = true
    do:
      writeAll(master, "\x11")     # Ctrl-Q
      await sleepAsync(30.milliseconds)
      check fired
      check stream.nextKey().finished == false   # queue empty

  test "does not fire on non-matching key":
    var fired = false
    withRig:
      hotkey stream, ctrlKey('q'):
        fired = true
    do:
      writeAll(master, "a")
      let ev = await stream.nextKey().wait(200.milliseconds)
      check ev.kind == kChar
      check not fired

  test "scope dispose unregisters the hotkey":
    var fired = false
    proc body() {.async: (raises: [Exception]).} =
      let (master, slave) = openPtyPair()
      let stream = newInputStream(slave)
      fresco_input.start(stream)
      defer:
        fresco_input.stop(stream)
        discard close(master)
        discard close(slave)
      let scope = newScope()
      withScope(scope):
        hotkey stream, ctrlKey('q'):
          fired = true
      dispose(scope)
      writeAll(master, "\x11")
      let ev = await stream.nextKey().wait(200.milliseconds)
      check ev.kind == kCtrl and ev.ch == 'q'
      check not fired
    waitFor body()

  test "multiple hotkeys coexist; only matching one fires":
    var firedQ = false
    var firedH = false
    withRig:
      hotkey stream, ctrlKey('q'):
        firedQ = true
      hotkey stream, simple(kF1):
        firedH = true
    do:
      writeAll(master, "\x1bOP")   # F1
      await sleepAsync(30.milliseconds)
      check firedH
      check not firedQ
