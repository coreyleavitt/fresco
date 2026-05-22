## Hotkey integration tests over a real PTY pair.

import std/unittest
import std/[posix, termios]
import chronos
import fresco/events
import fresco/input as fresco_input
import intonaco/reactive/scope
import fresco/hotkey

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
      check ev == ctrlKey('q')
      check not fired
    waitFor body()

  test "hotkey body that disposes the registering scope doesn't corrupt filter iteration":
    # Regression: runFilters used to iterate s.filters by ref; a
    # hotkey body that disposed its scope (which calls removeFilter)
    # could corrupt the in-progress for-loop and skip later filters.
    var fired1 = false
    var fired2 = false
    proc body() {.async: (raises: [Exception]).} =
      let (master, slave) = openPtyPair()
      let stream = newInputStream(slave)
      fresco_input.start(stream)
      defer:
        fresco_input.stop(stream)
        discard close(master)
        discard close(slave)
      let scopeA = newScope()
      let scopeB = newScope()
      # Two hotkeys on different keys; scopeA's body disposes scopeA
      # synchronously inside the filter callback.
      withScope(scopeA):
        hotkey stream, ctrlKey('q'):
          fired1 = true
          dispose(scopeA)        # ← would corrupt iteration before fix
      withScope(scopeB):
        hotkey stream, ctrlKey('w'):
          fired2 = true
      writeAll(master, "\x11")   # Ctrl-Q — fires scopeA's hotkey
      await sleepAsync(30.milliseconds)
      writeAll(master, "\x17")   # Ctrl-W — must still fire scopeB's
      await sleepAsync(30.milliseconds)
      check fired1
      check fired2
      dispose(scopeB)
    waitFor body()

  test "#68-family: N>=3 filters; middle disposal during one's dispatch":
    # Sibling of the #68 cursor-inference hazard at the
    # InputStream.filters site. Three hotkeys on DIFFERENT keys
    # (so they don't consume each other). A's body disposes B's
    # scope synchronously, removing B's filter mid-dispatch. We
    # then send keys that should fire C and confirm C still fires
    # — i.e. C's filter wasn't corrupted off the list by B's
    # mid-iteration removal.
    var firedA, firedC = 0
    proc body() {.async: (raises: [Exception]).} =
      let (master, slave) = openPtyPair()
      let stream = newInputStream(slave)
      fresco_input.start(stream)
      defer:
        fresco_input.stop(stream)
        discard close(master)
        discard close(slave)
      let scopeA = newScope()
      let scopeB = newScope()
      let scopeC = newScope()
      withScope(scopeA):
        hotkey stream, ctrlKey('q'):
          inc firedA
          dispose(scopeB)             # ← removes B's filter mid-dispatch
      withScope(scopeB):
        hotkey stream, ctrlKey('w'):
          discard                       # never fires; gets disposed
      withScope(scopeC):
        hotkey stream, ctrlKey('e'):
          inc firedC
      writeAll(master, "\x11")           # Ctrl-Q → A fires, disposes B
      await sleepAsync(30.milliseconds)
      writeAll(master, "\x05")           # Ctrl-E → C must still fire
      await sleepAsync(30.milliseconds)
      check firedA == 1
      check firedC == 1
      dispose(scopeA); dispose(scopeC)
    waitFor body()

  test "multiple hotkeys coexist; only matching one fires":
    var firedQ = false
    var firedH = false
    withRig:
      hotkey stream, ctrlKey('q'):
        firedQ = true
      hotkey stream, atomKey(kF1):
        firedH = true
    do:
      writeAll(master, "\x1bOP")   # F1
      await sleepAsync(30.milliseconds)
      check firedH
      check not firedQ
