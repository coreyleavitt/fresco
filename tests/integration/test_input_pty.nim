## Integration test: drive InputStream against a PTY pair.
##
## We open a PTY, attach an InputStream to the slave fd, write bytes
## into the master, and assert the decoded KeyEvents come out the
## stream's queue.

import std/[unittest, strutils]
import std/[posix, termios, unicode]
import chronos
import fresco/input as fresco_input
import fresco/events
import intonaco/task/mailbox
import fresco/receive

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

  test "EOF on the master side tears down the stream":
    # Regression for round-5 L5: when the PTY master is closed, the
    # slave reads return 0 indefinitely. Without onReadable's EOF
    # handling, the dispatcher would re-arm the reader and spin in a
    # zero-byte read loop. The fix calls stop() on first all-zero
    # wakeup, which wakes pending nextKey awaiters with
    # InputStreamClosedError.
    proc body() {.async: (raises: [Exception]).} =
      let (master, slave) = openPtyPair()
      let stream = newInputStream(slave)
      fresco_input.start(stream)
      defer:
        discard close(slave)
      let pending = stream.nextKey()
      await sleepAsync(20.milliseconds)
      check not pending.finished
      # Close the master — slave reads return EOF.
      discard close(master)
      var raised = false
      try:
        discard await pending.wait(500.milliseconds)
      except InputStreamClosedError:
        raised = true
      except CancelledError:
        raised = true
      check raised
    waitFor body()

  test "#71 tracer: nextKey is cancel-safe — bytes survive cancel + re-issue":
    # The receive macro's `finally:` calls `cancelSoon` on losing
    # sources' nextEvent futures. Two failure modes:
    #   (a) cancel arrives after queue.get already dequeued an event
    #       → event must be re-queued, not silently lost.
    #   (b) cancel arrives while queue.get is still waiting. chronos's
    #       race() doesn't propagate cancellation to children, so the
    #       inner popFirst keeps running; if a byte arrives later, it
    #       gets orphaned inside the dropped get-future. Either way
    #       the byte must be retrievable by the next nextKey.
    proc body() {.async: (raises: [Exception]).} =
      withStream:
        # Cancel-while-pending: nextKey starts with empty queue,
        # gets cancelled, then a byte arrives. The byte must reach
        # the next nextKey call.
        let f = stream.nextKey()
        f.cancelSoon()
        try: discard await f
        except CancelledError: discard
        writeAll(master, "y")
        let ev = await stream.nextKey().wait(500.milliseconds)
        check ev.kind == kChar
        check ev.rune == Rune('y')
    waitFor body()

  test "#71 cancel before any byte arrives leaves queue clean — no spurious drops":
    # Sanity: cancelling a nextKey that never saw a byte (cancel
    # propagated before any put) must not requeue anything bogus.
    # The next byte to arrive is delivered intact.
    proc body() {.async: (raises: [Exception]).} =
      withStream:
        let initialDropped = stream.droppedEvents
        let f = stream.nextKey()
        f.cancelSoon()
        try: discard await f
        except CancelledError: discard
        await sleepAsync(20.milliseconds)  # let any spurious enqueue settle
        check stream.droppedEvents == initialDropped
        writeAll(master, "z")
        let ev = await stream.nextKey().wait(500.milliseconds)
        check ev.rune == Rune('z')
    waitFor body()

  test "#71 restoreEvent: simultaneous receive finish hands the loser back":
    # Both sources have events ready when `receive` enters: stream
    # has a queued byte, mailbox has a queued value. Receive picks
    # one synchronously; the macro's finally calls `restoreEvent`
    # on the loser. The loser's value must be available for a
    # subsequent direct nextEvent on it.
    proc body() {.async: (raises: [Exception]).} =
      withStream:
        let m = newMailbox[int]()
        writeAll(master, "x")
        await sleepAsync(20.milliseconds)   # ensure byte is queued
        m.push(42)
        var picked = ""
        receive:
          on stream as ev:
            Char(c): picked = "stream:" & $c
          on m as v:
            picked = "mailbox:" & $v
        if picked.startsWith("stream"):
          # mailbox lost; its value must still be retrievable
          let v = await m.nextEvent()
          check v == 42
        else:
          # stream lost; its byte must still be retrievable
          let ev = await stream.nextKey().wait(200.milliseconds)
          check ev.rune == Rune('x')
    waitFor body()

  test "#71 headline: multi-source receive — stream survives an off-stream wake":
    # The amoxtli repro pattern: a non-stream source (Mailbox) wins
    # the multi-source receive; the macro's `finally:` cancels the
    # stream's nextEvent. A byte typed afterwards must reach a
    # subsequent receive on the stream.
    proc body() {.async: (raises: [Exception]).} =
      withStream:
        let m = newMailbox[int]()
        # Wake the mailbox immediately; the byte arrives after.
        proc driver() {.async.} =
          await sleepAsync(10.milliseconds); m.push(1)
          await sleepAsync(20.milliseconds); writeAll(master, "y")
        asyncSpawn driver()
        var firstArm = ""
        receive:
          on stream as ev:
            Char(c): firstArm = "stream:" & $c
            _:       firstArm = "stream-other"
          on m as _:
            firstArm = "mailbox"
        check firstArm == "mailbox"        # mailbox won
        # Now the byte 'y' arrives mid-second-receive. Pre-fix it
        # would be orphaned in the cancelled stream-nextEvent.
        var secondArm = ""
        receive:
          on stream as ev:
            Char(c): secondArm = "char:" & $c
          after 500.milliseconds:
            secondArm = "timeout"
        check secondArm == "char:y"
    waitFor body()

  test "bounded queue overflow increments droppedEvents":
    # Regression for round-5 M2: the dropped-events counter was added
    # in round 4 but never tested. A bounded queue (maxsize > 0) that
    # fills up should silently drop the excess but bump the counter.
    proc body() {.async: (raises: [Exception]).} =
      let (master, slave) = openPtyPair()
      # queueSize = 2 so we can overflow it deterministically.
      let stream = newInputStream(slave, queueSize = 2)
      fresco_input.start(stream)
      defer:
        fresco_input.stop(stream)
        discard close(master); discard close(slave)
      writeAll(master, "abcde")     # 5 char events; queue can hold 2
      await sleepAsync(50.milliseconds)
      check stream.droppedEvents >= 1
      # Drain the two that did fit so the rest of the suite stays clean.
      discard await stream.nextKey()
      discard await stream.nextKey()
    waitFor body()
