## parallel: integration tests — structured concurrency over multiple
## child tasks.

import std/unittest
import chronos
import fresco/reactive/scope
import fresco/task/core
import fresco/task/parallel

proc tick(): Future[void] {.async: (raises: [CancelledError]).} =
  await sleepAsync(0.milliseconds)

suite "parallel:":

  test "awaits all children before returning":
    proc body() {.async: (raises: [Exception]).} =
      var doneA = false
      var doneB = false
      var doneC = false
      proc a() {.async: (raises: [Exception]).} =
        await sleepAsync(5.milliseconds); doneA = true
      proc b() {.async: (raises: [Exception]).} =
        await sleepAsync(10.milliseconds); doneB = true
      proc c() {.async: (raises: [Exception]).} =
        await sleepAsync(15.milliseconds); doneC = true
      parallel:
        discard spawn a()
        discard spawn b()
        discard spawn c()
      check doneA and doneB and doneC
    waitFor body()

  test "empty block is a no-op and restores collector":
    proc body() {.async: (raises: [Exception]).} =
      let before = parallelCollector
      parallel: discard
      # The collector threadvar must be back to its pre-block value
      # even when the block did nothing.
      check parallelCollector == before
    waitFor body()

  test "one child raising cancels its siblings and re-raises":
    proc body() {.async: (raises: [Exception]).} =
      var siblingCancelled = false
      proc raiser() {.async: (raises: [Exception]).} =
        await sleepAsync(5.milliseconds)
        raise newException(ValueError, "boom")
      proc sibling() {.async: (raises: [Exception]).} =
        try:
          await sleepAsync(500.milliseconds)
        except CancelledError:
          siblingCancelled = true
          raise
      var caught = false
      try:
        parallel:
          discard spawn raiser()
          discard spawn sibling()
      except ValueError:
        caught = true
      check caught
      await tick(); await tick()
      check siblingCancelled
    waitFor body()

  test "synchronously-completing task is not dropped from parallel join":
    # Regression for round-4 H5: previously spawn called wireLifecycle
    # BEFORE adding the Mount to parallelCollector. wireLifecycle's
    # future-completion callback fires synchronously for an async proc
    # with no awaits, disposing the scope before the parallelCollector
    # add happened — the task was silently dropped from the join group.
    # Fix: add to parallelCollector first.
    proc body() {.async: (raises: [Exception]).} =
      var ran = 0
      proc immediate() {.async: (raises: [Exception]).} =
        # No await — runs to completion synchronously when called.
        inc ran
      parallel:
        discard spawn immediate()
        discard spawn immediate()
        discard spawn immediate()
      check ran == 3
    waitFor body()

  test "children inherit the parallel block's scope":
    proc body() {.async: (raises: [Exception]).} =
      let outer = newScope()
      var parents: seq[Scope] = @[]
      withScope(outer):
        proc work() {.async: (raises: [Exception]).} =
          await sleepAsync(5.milliseconds)
        parallel:
          let mA = spawn work()
          let mB = spawn work()
          parents.add mA.scope.parent
          parents.add mB.scope.parent
      # Both children's parent should be the same scope (the parallel scope).
      check parents.len == 2
      check parents[0] == parents[1]
    waitFor body()
