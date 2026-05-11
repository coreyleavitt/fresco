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

  test "empty block is a no-op":
    proc body() {.async: (raises: [Exception]).} =
      parallel: discard
      check true   # didn't hang
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
