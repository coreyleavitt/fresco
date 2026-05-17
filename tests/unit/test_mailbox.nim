## Mailbox[T] — typed event source for selective receive (#66).
##
## A producer-consumer queue with the same shape as InputStream but
## carrying a user-defined event type. Implements the EventSource
## protocol (nextEvent: Future[T]) so it can be one of multiple
## sources in a `receive` block.

import std/unittest
import chronos
import fresco/task/mailbox

suite "Mailbox: push + nextEvent":

  test "tracer: push then nextEvent returns the pushed value":
    proc body() {.async: (raises: [Exception]).} =
      let m = newMailbox[int]()
      m.push(42)
      let got = await m.nextEvent()
      check got == 42
    waitFor body()

  test "multiple pushes deliver in FIFO order":
    proc body() {.async: (raises: [Exception]).} =
      let m = newMailbox[string]()
      m.push("a"); m.push("b"); m.push("c")
      check (await m.nextEvent()) == "a"
      check (await m.nextEvent()) == "b"
      check (await m.nextEvent()) == "c"
    waitFor body()

  test "push wakes a suspended nextEvent awaiter":
    proc body() {.async: (raises: [Exception]).} =
      let m = newMailbox[int]()
      proc waker(): Future[void] {.async.} =
        await sleepAsync(5.milliseconds)
        m.push(7)
      asyncSpawn waker()
      let got = await m.nextEvent()
      check got == 7
    waitFor body()

  test "close raises MailboxClosedError on a waiting nextEvent":
    proc body() {.async: (raises: [Exception]).} =
      let m = newMailbox[int]()
      proc closer(): Future[void] {.async.} =
        await sleepAsync(5.milliseconds)
        m.close()
      asyncSpawn closer()
      var raised = false
      try:
        discard await m.nextEvent()
      except MailboxClosedError:
        raised = true
      check raised
    waitFor body()

  test "push after close is silently dropped":
    let m = newMailbox[int]()
    m.close()
    m.push(99)        # no raise; just dropped
    # Nothing observable to check beyond "didn't crash" — the next
    # nextEvent (if a fresh mailbox is created) wouldn't see this
    # value because the closed mailbox accepts nothing.

  test "nextEvent on already-closed mailbox raises immediately":
    proc body() {.async: (raises: [Exception]).} =
      let m = newMailbox[int]()
      m.close()
      var raised = false
      try:
        discard await m.nextEvent()
      except MailboxClosedError:
        raised = true
      check raised
    waitFor body()
