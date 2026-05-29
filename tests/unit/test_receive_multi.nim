## Multi-source selective receive (#66).
##
## The generalized `receive:` with `on <source> as <var>:` blocks
## races multiple typed event sources and dispatches arms based on
## which fired. Replaces the inject+kWake design with a cleanly-
## typed CSP/Erlang-style selective receive.

import std/unittest
import chronos
import intonaco/reactive
import fresco/receive

suite "receive: multi-source dispatch":

  test "tracer: single `on` block delivers an event from a mailbox":
    proc body() {.async: (raises: [Exception]).} =
      let m = newMailbox[int]()
      m.push(42)
      var got = -1
      receive:
        on m as ev:
          got = ev
      check got == 42
    waitFor body()

  test "two `on` blocks: only the source that fired runs its body":
    proc body() {.async: (raises: [Exception]).} =
      let a = newMailbox[int]()
      let b = newMailbox[string]()
      a.push(7)                  # only `a` has an event
      var aGot = -1; var bGot = ""
      receive:
        on a as ev:
          aGot = ev
        on b as ev:
          bGot = ev
      check aGot == 7
      check bGot == ""           # b's body did not run
    waitFor body()

  test "two `on` blocks: the other source fires → only its body runs":
    proc body() {.async: (raises: [Exception]).} =
      let a = newMailbox[int]()
      let b = newMailbox[string]()
      b.push("hi")
      var aGot = -1; var bGot = ""
      receive:
        on a as ev:
          aGot = ev
        on b as ev:
          bGot = ev
      check aGot == -1
      check bGot == "hi"
    waitFor body()

  test "both sources have events ready: exactly one body runs":
    # `race` picks one winner; deterministically the first finished.
    # We don't assert which — just that exactly one body executed.
    proc body() {.async: (raises: [Exception]).} =
      let a = newMailbox[int]()
      let b = newMailbox[int]()
      a.push(1); b.push(2)
      var ranA = false; var ranB = false
      receive:
        on a as ev:
          ranA = true
        on b as ev:
          ranB = true
      check (ranA xor ranB)      # exactly one fired
    waitFor body()

  test "`after` fires when no source produces in the window":
    proc body() {.async: (raises: [Exception]).} =
      let m = newMailbox[int]()
      var fired = false
      receive:
        on m as ev:
          fired = true
        after 20.milliseconds:
          discard               # timeout body
      check not fired           # source didn't fire; after did
    waitFor body()

  test "push during the wait wakes the receive and runs that source's body":
    proc body() {.async: (raises: [Exception]).} =
      let m = newMailbox[int]()
      proc pusher() {.async.} =
        await sleepAsync(5.milliseconds)
        m.push(99)
      asyncSpawn pusher()
      var got = -1
      receive:
        on m as ev:
          got = ev
        after 500.milliseconds:
          discard
      check got == 99
    waitFor body()

  test "cancel safety: losing source's event survives the race, retrievable later":
    # When source A wins, the macro cancels source B's nextEvent in
    # `finally:`. The cancel must NOT lose a value that was already
    # in B's queue. The next nextEvent on B must return that value.
    # This is the regression the issue called out (#66, Approach A
    # cancel race).
    proc body() {.async: (raises: [Exception]).} =
      let a = newMailbox[int]()
      let b = newMailbox[int]()
      a.push(1)
      b.push(2)                     # both queues have one item
      var firstAGot, firstBGot = 0
      receive:                      # exactly one source wins
        on a as ev: firstAGot = ev
        on b as ev: firstBGot = ev
      # Confirm both queues haven't lost their events: a direct
      # nextEvent on the loser returns the queued value.
      if firstAGot != 0:           # a won; b should still have 2
        let v = await b.nextEvent()
        check v == 2
      else:                         # b won; a should still have 1
        let v = await a.nextEvent()
        check v == 1
    waitFor body()
