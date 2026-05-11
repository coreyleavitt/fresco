## Integration test: drive InputStream against a PTY pair.
##
## We open a PTY, attach an InputStream to the slave fd, write bytes
## into the master, and assert the decoded KeyEvents come out the
## stream's queue.

import std/unittest
import std/[posix, termios, unicode]
import chronos
import fresco/input as fresco_input
import fresco/events

proc posix_openpt(flags: cint): cint {.importc, header: "<stdlib.h>".}
proc grantpt(fd: cint): cint           {.importc, header: "<stdlib.h>".}
proc unlockpt(fd: cint): cint          {.importc, header: "<stdlib.h>".}
proc ptsname(fd: cint): cstring        {.importc, header: "<stdlib.h>".}

proc openPtyPair(): tuple[master, slave: cint] =
  let master = posix_openpt(O_RDWR or O_NOCTTY)
  doAssert master >= 0
  doAssert grantpt(master) == 0
  doAssert unlockpt(master) == 0
  let name = ptsname(master)
  doAssert name != nil
  let slave = open(name, O_RDWR or O_NOCTTY)
  doAssert slave >= 0
  return (master, slave)

proc writeAll(fd: cint, s: string) =
  if s.len == 0: return
  let n = posix.write(fd, unsafeAddr s[0], s.len)
  doAssert n == s.len

template withStream(body: untyped) =
  ## Open PTY, wire up an InputStream on the slave, expose `master`
  ## and `stream` to the body. Always tears down.
  let (masterIdent, slaveIdent) = openPtyPair()
  let master {.inject.} = masterIdent
  let stream {.inject.} = newInputStream(slaveIdent)
  fresco_input.start(stream)
  defer:
    fresco_input.stop(stream)
    discard close(masterIdent)
    discard close(slaveIdent)
  body

proc collect(s: InputStream, n: int, timeout = 200.milliseconds):
    Future[seq[KeyEvent]] {.async.} =
  ## Read exactly `n` events or fail when `timeout` elapses.
  result = newSeqOfCap[KeyEvent](n)
  while result.len < n:
    let ev = await s.nextKey().wait(timeout)
    result.add ev

suite "InputStream over PTY":

  test "ASCII chars round-trip":
    proc body() {.async: (raises: [Exception]).} =
      withStream:
        writeAll(master, "abc")
        let evs = await collect(stream, 3)
        check evs == @[
          charKey(Rune('a')),
          charKey(Rune('b')),
          charKey(Rune('c')),
        ]
    waitFor body()

  test "Ctrl-C arrives as kCtrl 'c'":
    proc body() {.async: (raises: [Exception]).} =
      withStream:
        writeAll(master, "\x03")
        let evs = await collect(stream, 1)
        check evs == @[ctrlKey('c')]
    waitFor body()

  test "arrow-up sequence arrives as one event":
    proc body() {.async: (raises: [Exception]).} =
      withStream:
        writeAll(master, "\x1b[A")
        let evs = await collect(stream, 1)
        check evs == @[atomKey(kArrowUp)]
    waitFor body()

  test "bare ESC flushes via timeout":
    proc body() {.async: (raises: [Exception]).} =
      withStream:
        writeAll(master, "\x1b")
        let evs = await collect(stream, 1, timeout = 500.milliseconds)
        check evs == @[atomKey(kEscape)]
    waitFor body()

  test "stop() wakes pending nextKey awaiters with InputStreamClosedError":
    proc body() {.async: (raises: [Exception]).} =
      withStream:
        # Start a nextKey that has no events queued — it'll block.
        let pending = stream.nextKey()
        await sleepAsync(20.milliseconds)
        check not pending.finished
        # Close the stream; the awaiter should wake up.
        fresco_input.stop(stream)
        var raised = false
        try:
          discard await pending.wait(200.milliseconds)
        except InputStreamClosedError:
          raised = true
        except CancelledError:
          raised = true     # cancelSoon may surface as either
        check raised
    waitFor body()

  test "split arrow sequence reassembles across reads":
    proc body() {.async: (raises: [Exception]).} =
      withStream:
        writeAll(master, "\x1b")
        await sleepAsync(10.milliseconds)
        writeAll(master, "[B")
        let evs = await collect(stream, 1)
        check evs == @[atomKey(kArrowDown)]
    waitFor body()
