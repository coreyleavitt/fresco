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
