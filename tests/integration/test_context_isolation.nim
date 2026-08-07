## Coroutine-context isolation regression tests (#37).
##
## The three thread-locals fresco uses to attach context to async
## work — `currentScope`, `currentSpeculative`, `parallelCollector`
## — are declared via chronos's `contextVar:` macro in our chronos
## fork. The dispatcher captures the active contextVar storage at
## every `addCallback` / `callSoon` / `setTimer` and restores it
## before firing the callback. This file is the load-bearing proof:
## with concurrent tasks interleaved across awaits, each task's
## writes attribute to its own taskId regardless of which task was
## "last touched" the contextVar.
##
## If chronos ever rebases away from the contextVar primitive (or
## a new integration point is added that doesn't capture/restore),
## these tests turn red.

import std/[tables, unittest]
import chronos
include intonaco/reactive_internal

proc tick(): Future[void] {.async: (raises: [CancelledError]).} =
  await sleepAsync(0.milliseconds)

suite "context isolation: currentScope across interleaved awaits":

  setup:
    globalJournal = newJournal()

  teardown:
    resetJournal()

  test "task A writes x and y around await; task B writes z during await; attribution stays separate":
    # The acceptance criterion from #37.
    proc body() {.async: (raises: [Exception]).} =
      proc taskA() {.async.} =
        let x {.height: 0.} = signalC(0, label = "x")
        x.set(1)
        await sleepAsync(20.milliseconds)
        let y {.height: 0.} = signalC(0, label = "y")
        y.set(2)

      proc taskB() {.async.} =
        let z {.height: 0.} = signalC(0, label = "z")
        z.set(3)

      let mA = spawn taskA()
      # Give A a chance to start and reach its sleepAsync, then
      # spawn B during A's suspension.
      await sleepAsync(5.milliseconds)
      let mB = spawn taskB()
      await mB.wait()
      await mA.wait()

      # Group writes by signal label and assert attribution.
      var aTaskId, bTaskId = TaskId(0)
      var seen: Table[string, TaskId]
      for e in globalJournal.byKind(ekSignalWrite):
        seen[e.signalLabel] = e.taskId
      check seen["x"] == mA.scope.taskId
      check seen["y"] == mA.scope.taskId
      check seen["z"] == mB.scope.taskId

    waitFor body()

suite "context isolation: currentSpeculative across interleaved awaits":

  setup:
    globalJournal = newJournal()

  teardown:
    resetJournal()

  test "task A's speculative frame doesn't capture task B's writes during await":
    # If `currentSpeculative` leaks across coroutines, B's set() would
    # land in A's frame and get rolled back. The contextVar discipline
    # is what makes B's currentSpeculative `nil` (it's outside any
    # speculative: block), independent of A's binding.
    proc body() {.async: (raises: [Exception]).} =
      let a {.height: 0.} = signalC(10)
      let b {.height: 0.} = signalC(20)

      proc taskA(): Future[void] {.async: (raises: [Exception]).} =
        discard speculative:
          a.set(99)
          await sleepAsync(20.milliseconds)
          # Don't commit — the block exits with rollback on a.

      proc taskB() {.async.} =
        # B is OUTSIDE any speculative block. Its write should be
        # canonical and survive A's rollback.
        b.set(77)

      let mA = spawn taskA()
      await sleepAsync(5.milliseconds)
      let mB = spawn taskB()
      await mB.wait()
      await mA.wait()

      check a.peek() == 10     # A rolled back
      check b.peek() == 77     # B survived — wasn't captured by A's frame

    waitFor body()

suite "context isolation: parallelCollector across interleaved awaits":

  setup:
    globalJournal = newJournal()

  teardown:
    resetJournal()

  test "task B's spawn doesn't land in task A's parallel: collector":
    # A is inside parallel:. It spawns one child, awaits, spawns
    # another. Between those spawns, task B (independent) spawns
    # its own work. If parallelCollector leaked across coroutines,
    # B's spawn would land in A's collector and A would hang waiting
    # for B's task to complete (it might or might never).
    proc body() {.async: (raises: [Exception]).} =
      var aChildren = 0
      var bRan = false

      proc childA() {.async.} =
        await sleepAsync(2.milliseconds)
        inc aChildren

      proc childB() {.async.} =
        bRan = true

      proc taskA(): Future[void] {.async: (raises: [Exception]).} =
        parallel:
          discard spawn childA()
          await sleepAsync(15.milliseconds)
          discard spawn childA()

      let mA = spawn taskA()
      # During A's mid-parallel sleep, spawn B's independent task.
      await sleepAsync(5.milliseconds)
      let mB = spawn childB()
      await mB.wait()
      await mA.wait()

      check bRan                   # B completed on its own
      check aChildren == 2         # A waited for exactly its 2 children
      # Strong invariant: had B leaked into A's collector, A's
      # parallel: block would have awaited B too — but B had no
      # journal/scope side-effect on A.

    waitFor body()

suite "context isolation: deeper interleaves":

  setup:
    globalJournal = newJournal()

  teardown:
    resetJournal()

  test "three tasks ping-pong with awaits; every write attributes to its origin":
    # A two-task test catches "binding survives one await"; three
    # tasks with each suspending after every write catches "binding
    # was captured fresh on EACH callback, not reused stale from the
    # last resumption."
    proc body() {.async: (raises: [Exception]).} =
      proc taskN(label: string) {.async.} =
        let s1 = signalC(0, label = label & "1")
        s1.set(1)
        await sleepAsync(2.milliseconds)
        let s2 = signalC(0, label = label & "2")
        s2.set(2)
        await sleepAsync(2.milliseconds)
        let s3 = signalC(0, label = label & "3")
        s3.set(3)

      let mA = spawn taskN("A")
      let mB = spawn taskN("B")
      let mC = spawn taskN("C")
      await mA.wait()
      await mB.wait()
      await mC.wait()

      # For each (task, label-prefix) pair, every write under that
      # prefix must attribute to that task's id — no cross-contamination.
      var byLabel: Table[string, TaskId]
      for e in globalJournal.byKind(ekSignalWrite):
        byLabel[e.signalLabel] = e.taskId
      for suffix in ["1", "2", "3"]:
        check byLabel["A" & suffix] == mA.scope.taskId
        check byLabel["B" & suffix] == mB.scope.taskId
        check byLabel["C" & suffix] == mC.scope.taskId

    waitFor body()

suite "context isolation: chronos integration sites":

  setup:
    globalJournal = newJournal()

  teardown:
    resetJournal()

  test "setTimer callback fires under the scope captured at registration":
    # Distinct integration site from `await` (which captures via the
    # async-macro's generated callback). Verifies chronos wraps
    # `setTimer` callbacks with `userCallback` so the context is
    # captured at registration and restored at fire time.
    proc body() {.async: (raises: [Exception]).} =
      var fireScopeTaskId = TaskId(0)
      proc taskA(): Future[void] {.async: (raises: [Exception]).} =
        proc cb(data: pointer) {.gcsafe, raises: [].} =
          # Inside the callback, currentScope must still be taskA's
          # — captured by setTimer's userCallback at registration.
          {.cast(gcsafe).}:
            if currentScope != nil:
              fireScopeTaskId = currentScope.taskId
        discard setTimer(Moment.fromNow(5.milliseconds), cb, nil)
        await sleepAsync(30.milliseconds)
      let mA = spawn taskA()
      await mA.wait()
      check fireScopeTaskId == mA.scope.taskId

    waitFor body()

  test "Future.addCallback fires under the scope captured at registration":
    proc body() {.async: (raises: [Exception]).} =
      var observedTaskId = TaskId(0)
      proc taskA(): Future[void] {.async: (raises: [Exception]).} =
        let f = newFuture[void]("ctx-test")
        proc cb(udata: pointer) {.gcsafe, raises: [].} =
          {.cast(gcsafe).}:
            if currentScope != nil:
              observedTaskId = currentScope.taskId
        f.addCallback(cb)
        # Schedule the future's completion from outside taskA's scope.
        proc completer() {.async.} =
          await sleepAsync(5.milliseconds)
          f.complete()
        discard spawn completer()
        await sleepAsync(30.milliseconds)
      let mA = spawn taskA()
      await mA.wait()
      check observedTaskId == mA.scope.taskId

    waitFor body()
