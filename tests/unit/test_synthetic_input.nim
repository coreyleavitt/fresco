## SyntheticInputStream (Split Phase 2).
##
## A no-fd InputStream constructor + pushKey helper. Lets headless
## tests feed KeyEvents into a fresco app's input loop without going
## through terminal escape-sequence encoding.

import std/unicode
import std/unittest
import chronos
import fresco/events
import fresco/headless/input
import fresco/input as fresco_input

suite "SyntheticInputStream: no-fd input substrate":

  test "pushed key events are received by nextKey in FIFO order":
    proc body() {.async: (raises: [Exception]).} =
      let s = newSyntheticInputStream()
      s.pushKey(charKey(Rune('a')))
      s.pushKey(charKey(Rune('b')))
      s.pushKey(charKey(Rune('c')))
      let a = await s.nextKey()
      let b = await s.nextKey()
      let c = await s.nextKey()
      check a.rune == Rune('a')
      check b.rune == Rune('b')
      check c.rune == Rune('c')
    waitFor body()

  test "nextKey blocks until pushKey arrives":
    var received: Rune = Rune('\0')
    proc consumer(s: InputStream) {.async: (raises: [Exception]).} =
      let ev = await s.nextKey()
      received = ev.rune

    proc body() {.async: (raises: [Exception]).} =
      let s = newSyntheticInputStream()
      let f = consumer(s)
      await sleepAsync(2.milliseconds)        # consumer awaiting
      check received == Rune('\0')            # nothing yet
      s.pushKey(charKey(Rune('z')))
      await f
      check received == Rune('z')
    waitFor body()

  test "M10: pushKey on a bounded queue drops overflow and counts droppedEvents":
    # Regression for stage-4 M10: pushKey called queue.putNoWait(ev)
    # with no exception handling, unlike the fd read path's `enqueue`
    # which catches AsyncQueueFullError and bumps droppedEvents. A
    # consumer following headless/input.nim's documented pattern for
    # bounded synthetic streams (`newInputStream(fd = -1, queueSize =
    # N)`) who pushed past capacity got an uncaught
    # AsyncQueueFullError out of pushKey — breaking harness totality.
    proc body() {.async: (raises: [Exception]).} =
      let s = fresco_input.newInputStream(fd = -1, queueSize = 2)
      s.pushKey(charKey(Rune('a')))
      s.pushKey(charKey(Rune('b')))
      s.pushKey(charKey(Rune('c')))   # overflow — must be dropped, not raise
      s.pushKey(charKey(Rune('d')))   # overflow — must be dropped, not raise
      check s.droppedEvents == 2
      let a = await s.nextKey()
      let b = await s.nextKey()
      check a.rune == Rune('a')
      check b.rune == Rune('b')
    waitFor body()
