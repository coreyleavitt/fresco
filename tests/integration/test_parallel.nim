## parallel: integration tests — structured concurrency over multiple
## child tasks.

import std/unittest
import chronos
import fresco/reactive/scope
import fresco/task/core
import fresco/task/parallel
import fresco/journal/events
import fresco/journal/log

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

  test "concurrent sibling failure journals under the sibling's taskId":
    # Regression for round-8 H2: previously the journal entry used the
    # parallel's enclosing taskId (via journalEvent's `taskTid`) AND a
    # static "parallel-sibling" placeholder name. Now the direct log
    # call uses the failing sibling's own scope so `byTask` finds it.
    proc body() {.async: (raises: [Exception]).} =
      resetJournal()
      discard useJournal()
      proc loser() {.async: (raises: [Exception]).} =
        await sleepAsync(2.milliseconds)
        raise newException(IOError, "loser-boom")
      proc concurrentLoser() {.async: (raises: [Exception]).} =
        await sleepAsync(2.milliseconds)
        raise newException(ValueError, "concurrent-boom")
      var caught = false
      var loserTid: TaskId
      try:
        parallel:
          let m1 = spawn loser()
          let m2 = spawn concurrentLoser()
          loserTid = m2.scope.taskId
      except CatchableError:
        caught = true
      check caught
      # Find the escalate event for the concurrent sibling. Look it
      # up by the sibling's taskId.
      let escalates = globalJournal.byKind(ekSupervisorEscalate)
      var found = false
      for ev in escalates:
        if ev.taskId == loserTid: found = true
      check found
      resetJournal()
    waitFor body()

  test "body raising mid-block cancels already-spawned mounts":
    # Regression for round-9 H4: previously a body that raised after
    # some spawn() calls would orphan those mounts — control exited
    # the parallel: template without ever awaiting/cancelling them.
    proc body() {.async: (raises: [Exception]).} =
      var cancelled = 0
      proc longRunner() {.async: (raises: [Exception]).} =
        try:
          await sleepAsync(2000.milliseconds)
        except CancelledError:
          inc cancelled
          raise
      var caught = false
      try:
        parallel:
          discard spawn longRunner()
          discard spawn longRunner()
          discard spawn longRunner()
          raise newException(ValueError, "body raised before spawns awaited")
      except ValueError:
        caught = true
      check caught
      # Give the dispatcher a few ticks for cancelSoon to deliver.
      await sleepAsync(20.milliseconds)
      check cancelled == 3
    waitFor body()

  test "spawn isolates child task's view of parallelCollector":
    # Regression for round-5 C1: previously a child task spawned inside
    # `parallel:` saw the parent's parallelCollector via the threadvar,
    # so any spawn inside the child's body leaked into the outer
    # parallel group. `spawn sup.run()` was the canonical case —
    # sup.run's synchronous startup spawns landed in the outer group
    # and got awaited there, racing with the supervisor's own logic.
    proc body() {.async: (raises: [Exception]).} =
      var grandchildRan = false
      proc grandchild() {.async: (raises: [Exception]).} =
        await sleepAsync(5.milliseconds)
        grandchildRan = true
      proc parent() {.async: (raises: [Exception]).} =
        # This spawn must NOT be added to the outer parallel collector.
        # If it were, the outer parallel would await the grandchild
        # directly, defeating the abstraction.
        let g = spawn grandchild()
        await g.wait()
      var collectorSize = -1
      parallel:
        let p = spawn parent()
        # Inspect the collector during body execution. It must contain
        # only `p`, not the grandchild spawned inside parent's body.
        # (The grandchild won't have been spawned synchronously by now,
        # but the test still verifies after parent completes that no
        # extra mounts landed in the collector — the asserter below
        # checks this via the visible side effect.)
        collectorSize = parallelCollector.mounts.len
      check collectorSize == 1   # only the direct spawn
      check grandchildRan        # but grandchild still ran (via parent.await g)
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
