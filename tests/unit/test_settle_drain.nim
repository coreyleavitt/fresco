## test_settle_drain.nim — RFC headless-quiescence slice B10: `Settle` union
## + drain-mode `runHeadless` wiring; slice B11: failure surfacing.
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
## B11 (below, "B11:" suites) converts the harness from raising to
## reporting (rfc §Design 5, "the primitive raises, the harness reports"):
## a per-event `DrainTimeoutError` is captured as a `SettleFailure(site:
## sfEvent, eventIndex: k)` and remaining events are NOT injected — the
## RFC's event-loop bullets say "short-circuit remaining events", not
## continue past a failed drain. A final-drain timeout is captured as
## `site: sfFinalDrain` and never propagates. An app future that fails
## lands its exception in `appError` instead of being silently discarded.
## `settled()` is the one-expression clean-run check.
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
import fresco/render/layout
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

suite "B11: clean runs are settled()":

  test "a clean settleDrain run is settled(), with no settle failures and no appError":
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 10, 40)
      let r = s.newRegion(1, 0, 9, 40)

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        r.set(["hello"])
        s.appendLine("line1")
        discard s.commit()
        let key = await stream.nextKey()
        discard key

      let fut = runHeadless(s, app, events = @[keyEv(atomKey(kEscape))],
                            settle = settleDrain())
      let ok = await fut.withTimeout(2.seconds)
      check ok
      let hr = fut.read()

      check hr.settled()
      check hr.settleFailures.len == 0
      check hr.appError.isNil
      check hr.committedRows == @["line1"]

    waitFor body()

  test "a clean settleFixed run is settled(), with no settle failures and no appError":
    ## Item 5 of B11's scope: settleFixed runs report settleFailures = @[]
    ## trivially, and settled() semantics hold there too — no fixed-path
    ## regression from the failure-surfacing fields landing on
    ## HeadlessResult.
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 10, 40)
      let r = s.newRegion(1, 0, 9, 40)

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        r.set(["hello"])
        s.appendLine("line1")
        discard s.commit()

      let result = await runHeadless(s, app, events = @[],
                                     settle = settleFixed())
      check result.settled()
      check result.settleFailures.len == 0
      check result.appError.isNil
      check result.committedRows == @["line1"]

    waitFor body()

suite "B11: an app that raises surfaces appError":

  test "an app that raises immediately reports appError and settled() is false":
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 10, 40)

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        raise newException(ValueError, "boom")

      let fut = runHeadless(s, app, events = @[], settle = settleDrain())
      let ok = await fut.withTimeout(2.seconds)
      check ok
      let hr = fut.read()

      check not hr.settled()
      check not hr.appError.isNil
      check hr.appError.msg == "boom"
      check hr.settleFailures.len == 0

    waitFor body()

  test "an app that crashes mid-script stops further injection and still reports appError":
    ## The app-death short-circuit (rfc §Design 5): "if appFut.finished
    ## before injection, stop injecting". Distinct from the drain-timeout
    ## short-circuit below — here the drain after each event always
    ## succeeds (nothing is ever busy); it's `appFut.finished` becoming
    ## true between events that must stop the remaining script.
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 10, 40)
      var delivered: seq[int] = @[]

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        let key1 = await stream.nextKey()
        discard key1
        delivered.add 1
        raise newException(ValueError, "crashed mid-script")

      let events = @[keyEv(atomKey(kEnter)), keyEv(atomKey(kEnter)),
                     keyEv(atomKey(kEscape))]
      let fut = runHeadless(s, app, events = events, settle = settleDrain())
      let ok = await fut.withTimeout(2.seconds)
      check ok
      let hr = fut.read()

      check delivered == @[1]
      check not hr.appError.isNil
      check hr.appError.msg == "crashed mid-script"
      check hr.settleFailures.len == 0
      check not hr.settled()

    waitFor body()

suite "B11: a stuck busy predicate reports a SettleFailure instead of raising":

  test "stuck busy on event k records a sfEvent failure and short-circuits the remaining script":
    ## Per rfc §Design 5's event-loop bullets: "on DrainTimeoutError,
    ## record a SettleFailure and short-circuit remaining events" — NOT
    ## continue. Event index 1 (the second keyEv, 0-based) never settles
    ## (the gate is held busy for 120ms, well past the 50ms drainTimeout);
    ## event index 2 (the escape key) must never be delivered.
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 10, 40)
      let gate = newBusyGate("stuck")
      var delivered: seq[int] = @[]

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        var n = 0
        while true:
          let key = await stream.nextKey()
          inc n
          delivered.add n
          if key.kind == kEscape:
            return
          if n == 2:
            proc holdBusy() {.async: (raises: [Exception]).} =
              withBusy(gate):
                await sleepAsync(120.milliseconds)
            asyncSpawn holdBusy()

      let events = @[keyEv(atomKey(kEnter)), keyEv(atomKey(kEnter)),
                     keyEv(atomKey(kEscape))]
      let fut = runHeadless(s, app, events = events, timeout = 200.milliseconds,
                            settle = settleDrain(busy = gate,
                                                 drainTimeout = 50.milliseconds))
      let ok = await fut.withTimeout(2.seconds)
      check ok
      let hr = fut.read()

      check not hr.settled()
      check hr.settleFailures.len == 1
      check hr.settleFailures[0].site == sfEvent
      check hr.settleFailures[0].eventIndex == 1
      check hr.settleFailures[0].clauses == {dcBusy}
      check delivered == @[1, 2]
      check hr.appError.isNil

    waitFor body()

  test "a stuck busy predicate that never clears fails both the event drain and the final drain":
    ## Same shape as above but the gate never releases (holds for the
    ## whole test), so the best-effort final drain (rfc §Design 5, "one
    ## final best-effort drain ... never raises out") also times out and
    ## contributes a second, sfFinalDrain failure — proving the final
    ## drain runs even after an earlier per-event SettleFailure, and that
    ## its own timeout is recorded rather than propagated.
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 10, 40)
      let gate = newBusyGate("stuck-forever")
      var delivered: seq[int] = @[]

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        var n = 0
        while true:
          let key = await stream.nextKey()
          inc n
          delivered.add n
          if key.kind == kEscape:
            return
          if n == 1:
            proc holdBusyForever() {.async: (raises: [Exception]).} =
              withBusy(gate):
                await sleepAsync(10.seconds)
            asyncSpawn holdBusyForever()

      let events = @[keyEv(atomKey(kEnter)), keyEv(atomKey(kEscape))]
      let fut = runHeadless(s, app, events = events, timeout = 100.milliseconds,
                            settle = settleDrain(busy = gate,
                                                 drainTimeout = 30.milliseconds))
      let ok = await fut.withTimeout(2.seconds)
      check ok
      let hr = fut.read()

      check not hr.settled()
      check hr.settleFailures.len == 2
      check hr.settleFailures[0].site == sfEvent
      check hr.settleFailures[0].eventIndex == 0
      check hr.settleFailures[0].clauses == {dcBusy}
      check hr.settleFailures[1].site == sfFinalDrain
      check hr.settleFailures[1].clauses == {dcBusy}
      check delivered == @[1]

    waitFor body()

suite "B11: a final-drain-only failure has an unrepresentable eventIndex":

  test "a drain failure only at the final capture drain records a single sfFinalDrain failure":
    ## No per-event failure at all (events = @[], so the per-event loop
    ## never runs) — the busy gate only goes stuck via a task spawned from
    ## inside the app body, so the only drain that ever observes it is the
    ## final pre-capture drain. `SettleFailure` is a discriminated union
    ## (rfc §Design 5): `eventIndex` is unrepresentable for `sfFinalDrain`
    ## by construction, not by convention — demonstrated below via the
    ## exhaustive `case` match rather than a sentinel value.
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 10, 40)
      let gate = newBusyGate("final-stuck")

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        proc holdBusyForever() {.async: (raises: [Exception]).} =
          withBusy(gate):
            await sleepAsync(10.seconds)
        asyncSpawn holdBusyForever()
        # Returns immediately; the gate stays busy for the rest of the test.

      let fut = runHeadless(s, app, events = @[],
                            settle = settleDrain(busy = gate,
                                                 drainTimeout = 50.milliseconds))
      let ok = await fut.withTimeout(2.seconds)
      check ok
      let hr = fut.read()

      check not hr.settled()
      check hr.settleFailures.len == 1
      check hr.settleFailures[0].clauses == {dcBusy}
      case hr.settleFailures[0].site
      of sfFinalDrain:
        discard   # correct — eventIndex is not even a field on this branch
      of sfEvent:
        check false   # wrong discriminant — would have an eventIndex field
      check hr.appError.isNil

    waitFor body()

# -----------------------------------------------------------------------
# B12: resize under drain.
#
# rfc-headless-quiescence.md §Model item 7 draws the line this slice
# proves in the full `runHeadless` harness: key delivery crosses a
# multi-hop dispatcher chain (closed by `dcDispatcher`), but
# `ievResize`'s `s.setSize(h, w)` -> `applySizeNow` is fully synchronous
# — no delivery chain to wait on. `applySizeNow` also marks EVERY region
# `pending = true` (the biggest dirty-set case in the codebase), so the
# thing actually worth proving under drain is the *other* half:
# `drainToIdle`'s paint postcondition must re-render the WHOLE resized
# surface correctly, and composition with the other clauses (`dcBusy`
# in particular) must still hold when a resize event is involved.
# -----------------------------------------------------------------------

suite "B12: resize under drain":

  test "a resize event under drain applies synchronously; the following drain paints the full resized surface (the biggest dirty-set case)":
    ## `applySizeNow` marks every region pending on resize. This proves
    ## `drainToIdle`'s paint postcondition (rfc §Design 3) re-renders the
    ## whole live band at the NEW geometry, not a stale/partial one, and
    ## that the geometry itself is visible to the app by the time the
    ## next event (the closing key) is delivered — i.e. no delivery-chain
    ## wait was needed for the resize to take effect.
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 10, 40)
      let r = s.newRegion(1, 0, 9, 40)

      var heightAfter = 0
      var widthAfter = 0

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        r.set(["v1"])
        s.appendLine("line1")
        discard s.commit()
        let key = await stream.nextKey()
        discard key
        heightAfter = s.layout.height
        widthAfter = s.layout.width

      let events = @[resizeEv(20, 60), keyEv(atomKey(kEscape))]
      let fut = runHeadless(s, app, events = events, settle = settleDrain())
      let ok = await fut.withTimeout(2.seconds)
      check ok
      let hr = fut.read()

      check heightAfter == 20
      check widthAfter == 60
      check hr.committedRows == @["line1"]
      # The paint postcondition re-rendered the full new geometry: 20
      # rows captured, not the pre-resize 10 and not a partial repaint.
      check hr.rows.len == 20
      check hr.settled()

    waitFor body()

  test "resize applies immediately even while an unrelated async turn is busy; the drain after it still waits the turn out before the next event is injected":
    ## Category D (rfc §Acceptance: "multi-turn — A/B/C composed per
    ## event") composed with a resize event specifically: `turn()` is
    ## spawned at app startup (independent of any injected event) and
    ## holds `gate` busy for a real 30ms. The resize event is injected
    ## while `gate` is still busy — `setSize` does not consult `dcBusy`
    ## at all (it only stages behind `commitInProgress`), so the geometry
    ## change lands on the same synchronous turn as the injection. The
    ## drain that follows the resize event, however, DOES have to wait
    ## the gate out before `runHeadless` injects the closing key — proven
    ## by the app observing the gate idle at key delivery.
    ##
    ## `turn()` deliberately touches no region: a resize that changes
    ## height leaves a previously bottom-anchored band stale until the
    ## consumer calls `reanchorBottom` (rfc out of scope here; S0b/S0c's
    ## documented gap) — orthogonal to what this test proves, so it is
    ## sidestepped rather than papered over.
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 10, 40)
      let gate = newBusyGate("startup")

      var gateBusyAtKeyDelivery = true
      var heightAtKeyDelivery = 0
      var widthAtKeyDelivery = 0
      var synced = false

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        proc turn() {.async: (raises: [Exception]).} =
          withBusy(gate):
            await sleepAsync(30.milliseconds)
            synced = true
        asyncSpawn turn()
        # Returns immediately; turn() is still in flight when the resize
        # event below is injected.
        let key = await stream.nextKey()
        discard key
        gateBusyAtKeyDelivery = gate.isBusy()
        heightAtKeyDelivery = s.layout.height
        widthAtKeyDelivery = s.layout.width

      let events = @[resizeEv(20, 60), keyEv(atomKey(kEscape))]
      let fut = runHeadless(s, app, events = events,
                            settle = settleDrain(busy = gate))
      let ok = await fut.withTimeout(2.seconds)
      check ok
      let hr = fut.read()

      check heightAtKeyDelivery == 20
      check widthAtKeyDelivery == 60
      check synced
      check not gateBusyAtKeyDelivery
      check hr.settled()

    waitFor body()

suite "B12: representative fixed-settle test ported to settleDrain":

  test "layout dimensions reflect new size after resize event (settleDrain port of test_headless_resize_inject.nim's settleFixed test)":
    ## Direct port of the test of the same name in
    ## test_headless_resize_inject.nim (S0b) — same screen, same events,
    ## same assertions — with `settle = settleDrain()` in place of that
    ## test's implicit `settleFixed()` default. No fixed sleep anywhere
    ## in this test; the original is left in place unported so both
    ## settle paths cover the same scenario (rfc B12: "both settle paths
    ## green").
    proc body() {.async: (raises: [Exception]).} =
      let sink = newMemorySink()
      let s = newInlineScreen(sink, 24, 80)

      var layoutHAfter = 0
      var layoutWAfter = 0

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        let key = await stream.nextKey()
        layoutHAfter = s.layout.height
        layoutWAfter = s.layout.width
        discard key

      let events = @[
        resizeEv(30, 120),
        keyEv(atomKey(kEscape)),
      ]
      let fut = runHeadless(s, app, events = events, settle = settleDrain())
      let ok = await fut.withTimeout(2.seconds)
      check ok
      let hr = fut.read()

      check layoutHAfter == 30
      check layoutWAfter == 120
      check hr.settled()

    waitFor body()

# -----------------------------------------------------------------------
# F1: CancelGrace expiry is representable — via the shared race()-based
# `teardownAppFut` routine (rfc-headless-quiescence.md, "the withTimeout
# correction"), not `withTimeout`.
#
# `chronos.withTimeout` cancels its target on timeout but its own return
# future resolves only once the target ACTUALLY finishes — for an app
# that survives cancellation (catches `CancelledError` and re-awaits),
# that is never, so a `withTimeout`-based teardown hangs the whole
# `runHeadless` call rather than bounding anything. Both overloads now
# race `appFut` against a plain timer instead, which resolves the instant
# either side finishes regardless of cooperation. Totality is a harness
# invariant, not a settle-mode-specific policy: the plain Layout overload
# and the InlineScreen overload (both settle kinds) share ONE teardown
# routine, so all three are exercised below.
# -----------------------------------------------------------------------

suite "F1: CancelGrace expiry is representable":

  test "an app whose cancellation is swallowed leaves cancelGraceExpired true and settled() false (InlineScreen, settleDrain)":
    ## The app catches `CancelledError` and keeps awaiting — it swallows
    ## the cancel `teardownAppFut`'s `appFut.cancelSoon()` delivers to its
    ## current `await` and loops back onto a fresh `sleepAsync`, so
    ## `appFut` itself never finishes. Pre-F1 this hung the whole
    ## `runHeadless` call (verified: `withTimeout`-based teardown never
    ## returned, even bounded by an outer 2s `withTimeout` at the test
    ## site — the outer wait itself only resolves once the INNER hang
    ## resolves, which for this app is never). Post-F1, `teardownAppFut`
    ## races `appFut` against plain timers, so `runHeadless` genuinely
    ## returns within `timeout + CancelGrace` plus a near-instant final
    ## drain (the screen is otherwise idle).
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 10, 40)

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        while true:
          try:
            await sleepAsync(10.seconds)
          except CancelledError:
            discard  # swallow the cancel and keep awaiting a fresh sleep

      let fut = runHeadless(s, app, events = @[], timeout = 50.milliseconds,
                            settle = settleDrain())
      let ok = await fut.withTimeout(2.seconds)
      check ok
      let hr = fut.read()

      check hr.cancelGraceExpired
      check hr.appError.isNil       # Cancelled, not Failed — chronos distinguishes the two
      check hr.settleFailures.len == 0
      check not hr.settled()

    waitFor body()

  test "the same cancellation-surviving app also returns cancelGraceExpired true on the plain Layout overload (totality, not a settle-mode split)":
    ## The plain Layout-based overload has no `Settle` union at all — it
    ## is inherently the "fixed settle" case (rfc §Out of scope). Pre-F1
    ## it built its own bare `try: await appFut except ...` tail with no
    ## bound whatsoever; post-F1 it shares the exact same `teardownAppFut`
    ## routine as the InlineScreen overload, so a cancellation-surviving
    ## app returns here too, not just under `settleDrain`.
    proc body() {.async: (raises: [Exception]).} =
      proc app(stream: InputStream, layout: Layout) {.async: (raises: [Exception]).} =
        while true:
          try:
            await sleepAsync(10.seconds)
          except CancelledError:
            discard  # swallow the cancel and keep awaiting a fresh sleep

      let fut = runHeadless(app, inputs = @[], timeout = 50.milliseconds)
      let ok = await fut.withTimeout(2.seconds)
      check ok
      let hr = fut.read()

      check hr.cancelGraceExpired
      check hr.appError.isNil
      check hr.settleFailures.len == 0
      check not hr.settled()

    waitFor body()

  test "a well-behaved app that honors cancellation promptly leaves cancelGraceExpired false and stays settled()":
    ## Routine-teardown guard: an app that outlives the script and honors
    ## a plain (cancellable) `sleepAsync` completes its cancellation well
    ## inside the 100ms `CancelGrace` — the ordinary "app outlives the
    ## script" shutdown path must stay invisible, exactly as it did before
    ## this field existed.
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 10, 40)

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        await sleepAsync(10.seconds)

      let fut = runHeadless(s, app, events = @[], timeout = 50.milliseconds,
                            settle = settleDrain())
      let ok = await fut.withTimeout(2.seconds)
      check ok
      let hr = fut.read()

      check not hr.cancelGraceExpired
      check hr.appError.isNil
      check hr.settleFailures.len == 0
      check hr.settled()

    waitFor body()
