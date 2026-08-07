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
