## test_drain_to_idle.nim — RFC headless-quiescence slice B6: drainToIdle
## single-read core.
##
## Per rfc-headless-quiescence.md Design 3 + Slices/B6: `DrainClause`,
## `DrainSpec`, and `drainToIdle*(screen: InlineScreen[MemorySink], ...)`
## with single-read semantics — `while failingClauses(...) != {}: await
## stepsAsync(1)` then `screen.paint()`. No deadline / DrainTimeoutError
## (B7) and no stability window / backoff (B8) yet — both deliberately
## deferred to keep this slice's RED-GREEN boundary clean.
##
## Every `drainToIdle` await below is wrapped in `.withTimeout(2.seconds)`
## per the RFC mandate: no CI job timeout exists, so a pump-loop bug must
## fail the test fast instead of wedging the suite.

{.experimental: "callOperator".}

import std/unittest
import std/strutils
import chronos
import intonaco/reactive
import fresco/events
import fresco/input
import fresco/inline_screen
import fresco/render/sink/memory
import fresco/headless/input as headless_input
import fresco/headless/runner

suite "B6: drainToIdle on an already-idle screen":

  test "drain on an already-idle screen returns and paints":
    ## A freshly-allocated region starts non-pending (per B4's
    ## test_surface_probes.nim), so surfaceIdle already holds before the
    ## drain and the loop exits on the very first failingClauses read —
    ## zero pumps. The paint() postcondition must still run: MemorySink's
    ## `rows` starts as an empty seq (newMemorySink()) and only gets
    ## sized to the layout on a `commit` — that's the observable effect
    ## to assert.
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 5, 20)
      discard s.newRegion(0, 0, 5, 20)
      check s.surfaceIdle()
      check s.sink.rows.len == 0  # pre-drain: paint() has not run yet

      let ok = await drainToIdle(s).withTimeout(2.seconds)
      check ok

      check s.sink.rows.len == 5  # post-drain: paint() ran (postcondition)

    waitFor body()

suite "B6: drainToIdle waits on the commit batcher":

  test "a scheduled commit completes and post-drain surfaceIdle() holds":
    ## logSink.append sets pendingCommit synchronously (before the
    ## callSoon that drives driveCommitStep — B4's test_surface_probes.nim
    ## already proves the synchronous flip), so the dcCommit clause fails
    ## immediately after append. The drain must pump until the async
    ## batcher finishes: surfaceIdle() (and the committed line landing in
    ## sink.committedRows) can only hold post-drain if drainToIdle
    ## actually waited on dcCommit rather than returning on its first read.
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 10, 40)
      check s.commitIdle()

      s.logSink.append("committed line")
      check not s.commitIdle()
      check not s.surfaceIdle()

      let ok = await drainToIdle(s).withTimeout(2.seconds)
      check ok

      check s.commitIdle()
      check s.surfaceIdle()
      check s.sink.committedRows == @["committed line"]

    waitFor body()

suite "B6: drainToIdle does not wait on layout dirtiness":

  test "drain does not wait on a dirty region (paints it instead)":
    ## `r.set(...)` marks the region pending but touches no commit-batcher
    ## or dispatcher state (model §3: layout dirtiness is a paint
    ## obligation, not in-flight async work) — no clause in failingClauses
    ## ever inspects it. The drain must return on its very first idle read
    ## (commitIdle/reactiveIdle/animationsIdle/dispatcher/busy are all
    ## already idle) and rely entirely on its paint() postcondition to
    ## clear the dirty region, rather than looping until anyPending clears
    ## on its own (nothing would ever clear it without a paint).
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 5, 20)
      let r = s.newRegion(0, 0, 5, 20)
      r.set(["dirty content"])

      check not s.surfaceIdle()   # region pending
      check s.commitIdle()        # but nothing queued in the commit batcher
      check s.sink.rows.len == 0  # not yet painted

      let ok = await drainToIdle(s).withTimeout(2.seconds)
      check ok

      check s.surfaceIdle()               # paint() cleared the pending flag
      check s.sink.rows[0] == "dirty content"

    waitFor body()

suite "B6: drainToIdle waits for synthetic key delivery (model §7, the dcDispatcher acceptance test)":

  test "a pushed key is fully delivered before the drain returns":
    ## `pushKey` is a synchronous `putNoWait` — delivery to the app's
    ## `nextKey()` continuation then crosses a multi-hop dispatcher chain
    ## (AsyncQueue getter wakeup -> popFirst completion -> nextKey's
    ## race() completion -> nextKey's own future -> app resumption). Every
    ## framework-visible clause (reactive/animations/commit) is vacuously
    ## idle for that entire flight, so only the dcDispatcher clause (ready
    ## callbacks pending) can make the drain wait for it. Assert
    ## app-visible state immediately after a SINGLE drainToIdle call, not
    ## final state (a trailing appFut/teardown wait would mask a
    ## regression here).
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 5, 20)
      let stream = newSyntheticInputStream()
      var keyReceived = false

      proc app() {.async: (raises: [Exception]).} =
        discard await stream.nextKey()
        keyReceived = true

      let appFut = app()
      stream.pushKey(atomKey(kEscape))
      check not keyReceived  # nothing has been pumped yet

      let ok = await drainToIdle(s).withTimeout(2.seconds)
      check ok

      check keyReceived  # the multi-hop delivery chain fully flushed

      await appFut

    waitFor body()

suite "B7: drainToIdle deadline + DrainTimeoutError":
  ## Per rfc-headless-quiescence.md Slices/B7 (stage-3 redesign, approved
  ## 2026-08-06): enforce the deadline and raise `DrainTimeoutError`
  ## (newException + field-assign idiom) naming the exact clauses still
  ## failing. Deadline liveness AND truth come from one armed
  ## `sleepAsync(spec.drainTimeout)` timer, not `Moment.now()` — see "Pump &
  ## liveness" for the stage-3 finding this closes: a bare `stepsAsync(1)`
  ## pump on an otherwise-dormant dispatcher blocks in `select()`
  ## indefinitely (the dispatcher's tick queue does not bound the select
  ## timeout), so without the armed timer a stuck `busy` predicate would
  ## never let the drain observe its own deadline. No stability window, no
  ## backoff (both deleted from the machine; B8 is adversarial tests only).

  test "a stuck busy predicate raises DrainTimeoutError naming exactly {dcBusy}, via its own deadline":
    ## Regression test for the stage-3 dormant-dispatcher hang: this must
    ## raise DrainTimeoutError well inside the drain's own 20ms
    ## drainTimeout, not get force-cancelled by the test-site's 2s
    ## withTimeout grace (the failure mode observed before the armed-timer
    ## fix — the outer bound winning the race would surface as
    ## CancelledError instead of DrainTimeoutError).
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 5, 20)
      discard s.newRegion(0, 0, 5, 20)

      proc stuckBusy(): bool {.gcsafe, raises: [].} = true

      let spec = DrainSpec(busy: stuckBusy, drainTimeout: 20.milliseconds)
      let start = Moment.now()
      let fut = drainToIdle(s, spec)
      let ok = await fut.withTimeout(2.seconds)
      let elapsed = Moment.now() - start
      check ok            # fut completed (with failure) inside the outer bound
      check fut.failed()
      # Internal-liveness assertion: the drain's OWN deadline fired this,
      # not the outer 2s grace — comfortably under half the outer bound.
      check elapsed < 1.seconds

      try:
        await fut
        check false        # must not reach here
      except DrainTimeoutError as e:
        check e.failingClauses == {dcBusy}
        check e.msg.len > 0
        check "dcBusy" in e.msg
      except CancelledError:
        check false        # would mean the outer withTimeout won the race

    waitFor body()

  test "idle-at-deadline breaks instead of raising: a microscopic drainTimeout on an idle screen succeeds promptly":
    ## `failingClauses` reads empty on the very first evaluation (the
    ## screen is already idle), so the loop breaks before ever consulting
    ## `deadlineFut` — no wait on the deadline timer at all. Asserts both
    ## the non-raise AND the promptness (elapsed stays far below
    ## drainTimeout's already-microscopic 1ms, let alone the 2s outer
    ## bound), so a regression that waited for the deadline before
    ## checking idleness would fail this even though it "succeeds".
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 5, 20)
      discard s.newRegion(0, 0, 5, 20)
      check s.surfaceIdle()

      let spec = DrainSpec(busy: nil, drainTimeout: 1.milliseconds)
      let start = Moment.now()
      let ok = await drainToIdle(s, spec).withTimeout(2.seconds)
      let elapsed = Moment.now() - start
      check ok
      check elapsed < 500.milliseconds  # broke on the first idle read
      check s.sink.rows.len == 5        # paint() postcondition still ran

    waitFor body()

suite "B7: drainToIdle and ignoreAnimations":
  ## `dcAnimations` + `spec.ignoreAnimations` interaction: a live perpetual
  ## tween (duration far longer than any drainTimeout used here) is the
  ## "never idle" case for the animations clause specifically.

  teardown:
    stopFrameClock()

  test "a live perpetual tween raises DrainTimeoutError naming exactly {dcAnimations}":
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 5, 20)
      discard s.newRegion(0, 0, 5, 20)

      let sig {.height: 0.} = signalC(0.0)
      discard tween(sig, 1.0, 5.seconds, esLinear)  # outlives every timeout below
      check not animationsIdle()

      let spec = DrainSpec(busy: nil, drainTimeout: 20.milliseconds)
      let fut = drainToIdle(s, spec)
      let ok = await fut.withTimeout(2.seconds)
      check ok
      check fut.failed()

      try:
        await fut
        check false
      except DrainTimeoutError as e:
        check e.failingClauses == {dcAnimations}
        check "dcAnimations" in e.msg

    waitFor body()

  test "ignoreAnimations=true settles despite a live perpetual tween":
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 5, 20)
      discard s.newRegion(0, 0, 5, 20)

      let sig {.height: 0.} = signalC(0.0)
      discard tween(sig, 1.0, 5.seconds, esLinear)
      check not animationsIdle()

      let spec = DrainSpec(busy: nil, drainTimeout: 500.milliseconds,
                           ignoreAnimations: true)
      let ok = await drainToIdle(s, spec).withTimeout(2.seconds)
      check ok
      check s.sink.rows.len == 5  # settled + painted despite the still-live tween

    waitFor body()

  test "ignoreAnimations=true excludes dcAnimations even when a concurrent dcBusy timeout fires":
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 5, 20)
      discard s.newRegion(0, 0, 5, 20)

      let sig {.height: 0.} = signalC(0.0)
      discard tween(sig, 1.0, 5.seconds, esLinear)
      check not animationsIdle()

      proc stuckBusy(): bool {.gcsafe, raises: [].} = true
      let spec = DrainSpec(busy: stuckBusy, drainTimeout: 20.milliseconds,
                           ignoreAnimations: true)
      let fut = drainToIdle(s, spec)
      let ok = await fut.withTimeout(2.seconds)
      check ok
      check fut.failed()

      try:
        await fut
        check false
      except DrainTimeoutError as e:
        check e.failingClauses == {dcBusy}       # exactly — dcAnimations excluded
        check dcAnimations notin e.failingClauses # despite the tween genuinely being live

    waitFor body()

suite "B8: adversarial tests of the single-read machine":
  ## Per rfc-headless-quiescence.md Slices/B8: the stability window and
  ## backoff were DELETED in the stage-3 redesign (see "Why there is no
  ## stability window or backoff") — a single idle read is sound because
  ## `dcDispatcher` is an exact witness for framework-visible work. B8 adds
  ## no production code; it is adversarial coverage proving that claim
  ## against the machine as it stands.

  test "a mid-drain clause flap (busy -> commit -> idle) is still caught: re-armed work is not lost":
    ## A background task the framework CANNOT see on its own (model §6:
    ## "app-level async the framework cannot see") sleeps a real 30ms, then
    ## appends a committed line and flips `rearmed`. `busy` is defined as
    ## exactly `not rearmed`, so it covers the whole 30ms span; the instant
    ## it releases, the append has *already* happened (same synchronous
    ## continuation), handing off to `dcCommit`/`dcDispatcher` for the one
    ## remaining dispatcher hop to actually finish the commit. This is a
    ## genuine clause handoff, not a single static condition: dcBusy is the
    ## only thing keeping the loop open for the first ~30ms (nothing
    ## framework-visible is pending yet — the task is plain-asleep), then
    ## dcCommit/dcDispatcher take over for the tail. If the drain returned
    ## before the 30ms elapsed (e.g. dcBusy silently ignored or read once
    ## and cached), the assertion below — checked essentially immediately
    ## after `drainToIdle` returns, well under 30ms of real wall-clock work
    ## remaining — would observe `committedRows` still empty.
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 5, 20)
      discard s.newRegion(0, 0, 5, 20)
      check s.surfaceIdle()

      var rearmed = false
      proc rearmTask() {.async: (raises: [Exception]).} =
        await sleepAsync(30.milliseconds)
        s.logSink.append("rearmed")  # framework-visible from this point on
        rearmed = true               # ...and busy releases from this point on

      asyncSpawn rearmTask()

      proc busyPred(): bool {.gcsafe, raises: [].} =
        not rearmed

      let spec = DrainSpec(busy: busyPred, drainTimeout: 2.seconds)
      let ok = await drainToIdle(s, spec).withTimeout(2.seconds)
      check ok

      check s.commitIdle()
      check s.surfaceIdle()
      check s.sink.committedRows == @["rearmed"]  # re-armed work landed, not lost

    waitFor body()

  test "sequential drainToIdle calls share no state: a timed-out drain does not affect the next":
    ## First drain: a stuck busy predicate forces a DrainTimeoutError on a
    ## small drainTimeout. Second drain: same screen, no busy clause,
    ## otherwise-idle — must succeed promptly and correctly, unaffected by
    ## the first drain's cancelled deadline timer or any other state the
    ## first call might have left behind (the machine holds no counters or
    ## shared state across calls by construction — this proves it).
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 5, 20)
      discard s.newRegion(0, 0, 5, 20)

      proc stuckBusy(): bool {.gcsafe, raises: [].} = true
      let spec1 = DrainSpec(busy: stuckBusy, drainTimeout: 20.milliseconds)
      let fut1 = drainToIdle(s, spec1)
      let ok1 = await fut1.withTimeout(2.seconds)
      check ok1
      check fut1.failed()
      try:
        await fut1
        check false
      except DrainTimeoutError as e:
        check e.failingClauses == {dcBusy}

      # Second drain on the same screen: no busy clause, nothing pending.
      let start = Moment.now()
      let ok2 = await drainToIdle(s).withTimeout(2.seconds)
      let elapsed = Moment.now() - start
      check ok2
      check elapsed < 500.milliseconds  # not delayed by anything left over
      check s.surfaceIdle()
      check s.sink.rows.len == 5

    waitFor body()

  test "already-idle drain with a LARGE drainTimeout returns promptly (regression guard for the deleted window's stall mode)":
    ## The deleted stability window re-confirmed idleness with a second
    ## pump before returning; under the event-driven pump a "confirm idle"
    ## pump on an already-idle screen blocks until the deadline (see RFC
    ## "Why there is no stability window or backoff"). This guards
    ## specifically against that regression at a LARGE drainTimeout (1s) —
    ## B7's microscopic-timeout test (1ms) cannot distinguish "broke on
    ## first read" from "waited a possibly-large fraction of a tiny
    ## timeout"; only a large timeout makes a reintroduced wait visible.
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 5, 20)
      discard s.newRegion(0, 0, 5, 20)
      check s.surfaceIdle()

      let spec = DrainSpec(busy: nil, drainTimeout: 1.seconds)
      let start = Moment.now()
      let ok = await drainToIdle(s, spec).withTimeout(2.seconds)
      let elapsed = Moment.now() - start
      check ok
      check elapsed < 200.milliseconds  # nowhere near the 1s drainTimeout
      check s.sink.rows.len == 5

    waitFor body()

suite "M7: two drains concurrently in flight on the same screen are safe by construction":
  ## Per rfc-headless-quiescence.md ~line 153: "two drains concurrently in
  ## flight are safe by construction (all shared reads are read-only
  ## probes; a double paint() is idempotent)". The B8 suite above only
  ## proves SEQUENTIAL drains (one finishes, THEN the next starts) share no
  ## state. Nothing before this suite starts two `drainToIdle` futures on
  ## the same screen before awaiting either.

  test "two drainToIdle futures started before either is awaited both complete cleanly with correct captured output":
    ## `s.logSink.append` sets `pendingCommit` synchronously (B4's
    ## test_surface_probes.nim), so `dcCommit` fails on the very first
    ## `failingClauses` read for BOTH futures — neither fast-paths on
    ## creation, so they genuinely overlap in the pump loop (each armed its
    ## own `deadlineFut`, each racing the same async commit batcher) rather
    ## than running one after the other.
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 5, 20)
      discard s.newRegion(0, 0, 5, 20)

      s.logSink.append("concurrent line")
      check not s.commitIdle()

      # Both created before either is awaited: each runs synchronously up
      # to its own first suspension (the commit batcher hasn't drained yet
      # for either), so both are genuinely mid-drain at this point.
      let f1 = drainToIdle(s)
      let f2 = drainToIdle(s)
      check not f1.finished
      check not f2.finished

      let ok1 = await f1.withTimeout(2.seconds)
      let ok2 = await f2.withTimeout(2.seconds)
      check ok1
      check ok2
      check not f1.failed()
      check not f2.failed()

      # Both completed cleanly, the screen ends idle, and the double
      # paint() (one from each drain) is idempotent: exactly one copy of
      # the committed line, and a correctly re-rendered live band.
      check s.surfaceIdle()
      check s.sink.committedRows == @["concurrent line"]
      check s.sink.rows.len == 5

    waitFor body()

  test "a drain with a stuck busy clause times out while a concurrent busy-free drain on the same screen completes cleanly":
    ## Confines `DrainTimeoutError` to the future that owns the stuck
    ## `busy` clause — the concurrent sibling with no busy clause must not
    ## be affected by (or itself raise because of) the other's timeout.
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 5, 20)
      discard s.newRegion(0, 0, 5, 20)

      proc stuckBusy(): bool {.gcsafe, raises: [].} = true
      let specBusy = DrainSpec(busy: stuckBusy, drainTimeout: 20.milliseconds)

      let fBusy = drainToIdle(s, specBusy)
      let fClean = drainToIdle(s)  # no busy clause; default 1s drainTimeout

      let okBusy = await fBusy.withTimeout(2.seconds)
      let okClean = await fClean.withTimeout(2.seconds)
      check okBusy
      check okClean

      check fBusy.failed()
      check not fClean.failed()

      try:
        await fBusy
        check false        # must not reach here
      except DrainTimeoutError as e:
        check e.failingClauses == {dcBusy}

      # The busy-free sibling settled and painted normally, unaffected by
      # the other's timeout.
      check s.surfaceIdle()
      check s.sink.rows.len == 5

    waitFor body()

suite "M8: drainToIdle's own cancellation contract":
  ## Per rfc-headless-quiescence.md ~line 155: "a CancelledError raised
  ## into the pump loop propagates out without painting". The existing F1
  ## cancellation tests (test_settle_drain.nim) only cancel the APP future
  ## via runHeadless's `teardownAppFut` — a different mechanism entirely,
  ## exercising the app's OWN cancellation handling, never `drainToIdle`'s.
  ## This suite cancels the `drainToIdle` FUTURE ITSELF while it is
  ## genuinely mid-pump.

  test "cancelSoon on a mid-pump drainToIdle raises CancelledError into the awaiter, paints nothing, and leaves the screen drainable again afterward":
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 5, 20)
      discard s.newRegion(0, 0, 5, 20)

      # A busy predicate held true forever is the "screen that stays
      # non-idle" case: every other clause (reactive/animations/commit/
      # dispatcher) already reads idle on a freshly-allocated region (no
      # logSink.append here — deliberately, so nothing but drainToIdle's
      # own paint() postcondition could ever populate sink.rows/
      # committedRows below), so dcBusy alone keeps the pump looping on
      # `await stepsAsync(1)` indefinitely, bounded only by the 5s
      # drainTimeout that the cancel below preempts.
      proc alwaysBusy(): bool {.gcsafe, raises: [].} = true
      let spec = DrainSpec(busy: alwaysBusy, drainTimeout: 5.seconds)

      let fut = drainToIdle(s, spec)
      # drainToIdle runs synchronously up to its first suspension point
      # (`await stepsAsync(1)`, since dcBusy fails on the very first
      # `failingClauses` read) — so it is already mid-pump here, not
      # merely scheduled.
      check not fut.finished

      fut.cancelSoon()
      # `withTimeout` cannot be awaited plainly here: chronos's own
      # implementation cancels its OWN returned future (rather than
      # completing it with `false`) when the WRAPPED future finishes
      # cancelled before the timeout elapses (`completeFuture`'s
      # `timeout == false` branch calls `retFuture.cancelAndSchedule()`)
      # — so a cancel that lands promptly surfaces as `CancelledError` out
      # of this very `await`, not as a `bool`. That exception IS the
      # bound-and-complete signal (it only fires once `fut` itself has
      # actually finished); a genuine failure-to-land past the 2s bound
      # instead returns `false` cleanly (chronos's own timeout path there
      # completes `retFuture` rather than cancelling it).
      var landed = false
      try:
        landed = await fut.withTimeout(2.seconds)
      except CancelledError:
        landed = fut.finished()  # the cancel already landed
      check landed             # the cancel actually lands (not lost)
      check fut.cancelled()

      # (a) awaiting a cancelled future raises CancelledError.
      var gotCancelled = false
      try:
        await fut
      except CancelledError:
        gotCancelled = true
      check gotCancelled

      # (b) no paint happened after cancellation. Nothing was ever queued
      # on the commit batcher, so the ONLY way sink.rows/committedRows
      # could become non-empty is drainToIdle's own paint() postcondition
      # (`screen.paint()`, reached only via the loop's `break`) — which
      # the cancellation, landing inside `await stepsAsync(1)`, must have
      # skipped entirely.
      check s.sink.rows.len == 0
      check s.sink.committedRows.len == 0

      # (c) the armed deadline timer was cleaned up. `deadlineFut` is
      # local to drainToIdle's own stack frame and unobservable from a
      # test directly, so — per the finding's fallback guidance — this
      # asserts the practical regression signal instead: a FRESH
      # drainToIdle on the SAME screen, now with no busy clause, still
      # completes cleanly and paints. If the cancelled call's `defer:
      # deadlineFut.cancelSoon()` had not run, or the cancel had left the
      # screen in a half-updated state, this next drain would hang, time
      # out unexpectedly, or observe corrupted screen state instead of
      # settling immediately.
      let cleanOk = await drainToIdle(s).withTimeout(2.seconds)
      check cleanOk
      check s.surfaceIdle()
      check s.sink.rows.len == 5

    waitFor body()
