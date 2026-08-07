## test_settle_drain.nim — RFC headless-quiescence slice B10: `Settle` union
## + drain-mode `runHeadless` wiring.
##
## Per rfc-headless-quiescence.md Design 5 + Slices/B10: `Settle` is a
## discriminated union (`skFixed`/`skDrain`, mirroring `InlineEvent` two
## types up in the same file) so the invalid combinations (`busy` under
## fixed settling, `perKeySettle` under drain) are unrepresentable.
## `settleFixed` remains the default — the fixed path must behave exactly
## as before this slice landed. `settleDrain` wires `drainToIdle(screen,
## spec.drain)` between injected events instead of `sleepAsync(perKeySettle)`,
## plus one final pre-capture drain (exercised even with zero events).
##
## B11 (SettleFailure/appError/settled()) is explicitly NOT this slice's
## concern: a drain timeout in drain mode propagates as an ordinary
## exception out of `runHeadless`, exactly like any other exception the
## harness doesn't special-case today.
##
## Every drain-mode `runHeadless` await below is wrapped in
## `.withTimeout(...)` per the house idiom (test_drain_to_idle.nim) so a
## pump-loop regression fails fast instead of wedging the suite.

{.experimental: "callOperator".}

import std/unittest
import chronos
import intonaco/reactive
import fresco/events
import fresco/input
import fresco/inline_screen
import fresco/render/sink/memory
import fresco/busy
import fresco/headless/input as headless_input
import fresco/headless/runner

suite "B10: settleFixed is the default — existing behavior untouched":

  test "runHeadless(screen, app, events) with no settle argument behaves exactly as before":
    ## No `settle:` argument at all — must still resolve to fixed-sleep
    ## settling (the RFC's `settle: Settle = settleFixed()` default), and
    ## produce the same committed/live-band capture the pre-B10 harness did.
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 10, 40)
      let r = s.newRegion(1, 0, 9, 40)

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        r.set(["hello"])
        s.appendLine("line1")
        discard s.commit()
        let key = await stream.nextKey()
        discard key

      let result = await runHeadless(s, app,
                                     events = @[keyEv(atomKey(kEscape))])
      check result.committedRows == @["line1"]
      check result.rows[1] == "hello"

    waitFor body()

  test "settleFixed() explicit matches the implicit default":
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 10, 40)
      let r = s.newRegion(1, 0, 9, 40)

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        r.set(["hello"])
        s.appendLine("line1")
        discard s.commit()

      let result = await runHeadless(s, app, events = @[],
                                     settle = settleFixed())
      check result.committedRows == @["line1"]
      check result.rows[1] == "hello"

    waitFor body()

suite "B10: settleDrain with zero events":

  test "events = @[] still performs the final drain and returns a coherent result":
    ## No events to inject — the app kicks off background work immediately
    ## via `asyncSpawn` and returns without awaiting it. With `settle =
    ## settleDrain(busy = gate)`, `runHeadless` must still run its final
    ## pre-capture drain (there is no per-event drain to have done it,
    ## since `events.len == 0`) before capturing — proving the final drain
    ## runs unconditionally, not merely "between events."
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 10, 40)
      let r = s.newRegion(1, 0, 9, 40)
      let gate = newBusyGate("startup")

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        proc startupSync() {.async: (raises: [Exception]).} =
          withBusy(gate):
            await sleepAsync(30.milliseconds)
            r.set(["synced"])
            s.appendLine("startup done")
            discard s.commit()
        asyncSpawn startupSync()
        # Returns immediately; startupSync() is still in flight.

      let fut = runHeadless(s, app, events = @[],
                            settle = settleDrain(busy = gate))
      let ok = await fut.withTimeout(2.seconds)
      check ok
      let hr = fut.read()

      check hr.committedRows == @["startup done"]
      check hr.rows[1] == "synced"
      check not gate.isBusy()

    waitFor body()

suite "B10: per-event intermediate-state assertion (the headline requirement)":

  test "key 1's async reaction is fully settled before key 2 is delivered to the app":
    ## Each key's handler spawns a background task (`asyncSpawn`) that
    ## holds a SHARED `BusyGate` open for a real 30ms before committing
    ## its line — the model-§6 "tasks spawned from the decide/act seam"
    ## shape: the framework (reactive/commit/dispatcher) sees nothing in
    ## flight during that 30ms, only the busy predicate does. The app's
    ## own `nextKey()` loop does NOT await the spawned task, so nothing
    ## about the app's internal control flow forces per-key ordering by
    ## itself; only `runHeadless`'s wiring of `drainToIdle(screen,
    ## settle.drain)` BETWEEN each injected event can make the harness
    ## wait out the gate before injecting the next key.
    ##
    ## Honest observation point (per the RFC's own hint: "study how
    ## runHeadless drives events"): the app records, into a harness-
    ## external `seq[bool]`, whether the SHARED gate is still busy at the
    ## instant each key is DELIVERED (`nextKey()` resumes). Delivery of
    ## key N+1 can only happen after `runHeadless`'s drain for key N has
    ## already returned (the harness injects strictly after that drain
    ## completes), so "gate idle at delivery" is equivalent to "key N's
    ## reaction was observably complete before key N+1 was injected." A
    ## fixed too-short settle (the pre-B10 default, 1ms) would leave the
    ## gate busy at key 2's delivery, since 1ms << the turn's 30ms span —
    ## this is exactly the class of flakiness a fixed sleep can't rule out
    ## and a drain can.
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 10, 40)
      let r = s.newRegion(1, 0, 9, 40)
      let gate = newBusyGate("turn")
      var gateBusyAtDelivery: seq[bool] = @[]
      var order: seq[string] = @[]

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        var n = 0
        while true:
          let key = await stream.nextKey()
          gateBusyAtDelivery.add gate.isBusy()
          if key.kind == kEscape:
            return
          inc n
          let myN = n
          proc turn() {.async: (raises: [Exception]).} =
            withBusy(gate):
              await sleepAsync(30.milliseconds)
              order.add("commit " & $myN)
              r.set(["count: " & $myN])
              s.appendLine("line " & $myN)
              discard s.commit()
          asyncSpawn turn()

      let events = @[keyEv(atomKey(kEnter)), keyEv(atomKey(kEnter)),
                     keyEv(atomKey(kEscape))]
      let fut = runHeadless(s, app, events = events,
                            settle = settleDrain(busy = gate))
      let ok = await fut.withTimeout(2.seconds)
      check ok
      let hr = fut.read()

      check gateBusyAtDelivery == @[false, false, false]
      check order == @["commit 1", "commit 2"]
      check hr.committedRows == @["line 1", "line 2"]

    waitFor body()

suite "B10: an async app turn settles deterministically in drain mode":

  test "a withBusy-gated turn triggered by a key event is fully reflected in the captured result, with no fixed margin in the test":
    ## Single busy-gated 40ms turn, spawned (not awaited inline) from the
    ## key handler so the app returns immediately and the turn is still in
    ## flight — only `drainToIdle`'s `dcBusy` clause (via the per-event
    ## drain, backstopped by the final drain) can make the harness wait
    ## for it before capture. Closes the loop from B9's isolated
    ## `drainToIdle` proof to the full `runHeadless` harness (upstream
    ## Category B, rfc §Acceptance) — no `sleepAsync` anywhere in this
    ## test itself, only the drain's exact busy-gate semantics.
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 10, 40)
      let r = s.newRegion(1, 0, 9, 40)
      let gate = newBusyGate("async-turn")

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        let key = await stream.nextKey()
        discard key
        proc turn() {.async: (raises: [Exception]).} =
          withBusy(gate):
            await sleepAsync(40.milliseconds)
            r.set(["settled"])
            s.appendLine("async line")
            discard s.commit()
        asyncSpawn turn()
        # Returns immediately; turn() is still in flight.

      let fut = runHeadless(s, app, events = @[keyEv(atomKey(kEnter))],
                            settle = settleDrain(busy = gate))
      let ok = await fut.withTimeout(2.seconds)
      check ok
      let hr = fut.read()

      check hr.committedRows == @["async line"]
      check hr.rows[1] == "settled"
      check not gate.isBusy()

    waitFor body()
