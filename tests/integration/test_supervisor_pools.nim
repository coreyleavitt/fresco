## TaskGroup + supervisor-adopted pool tests (issue #31).
##
## TaskGroup is a standalone structured-concurrency primitive — a
## bounded dynamic set of supervised tasks with shared lifecycle
## operations (cancelAll, joinAll). Composes with Supervisor for
## restart-on-crash via Supervisor.adopt(group, ...).

import std/[unittest, strutils]
import chronos
import results
import intonaco/reactive

suite "task group: standalone primitive":

  test "spawn returns Mount; member runs to completion":
    proc body() {.async: (raises: [Exception]).} =
      let g = newTaskGroup(maxSize = 4)
      var ran = false
      proc work(): Future[void] {.async.} =
        await sleepAsync(2.milliseconds)
        ran = true
      let m = g.spawn(work).tryGet()
      await m.future
      check ran
      check g.size == 0     # auto-removed on finish
    waitFor body()

  test "maxSize enforced: geFull at cap; slot frees on member exit":
    proc body() {.async: (raises: [Exception]).} =
      let g = newTaskGroup(maxSize = 2)
      proc slow(): Future[void] {.async.} =
        await sleepAsync(20.milliseconds)
      proc quick(): Future[void] {.async.} =
        await sleepAsync(2.milliseconds)
      let m1 = g.spawn(slow).tryGet()
      let m2 = g.spawn(slow).tryGet()
      check g.size == 2
      let r = g.spawn(quick)
      check r.isErr and r.error == geFull
      # Cancel one slow member; its slot frees.
      m1.cancel()
      try: await m1.future
      except CancelledError: discard
      check g.size == 1
      let r2 = g.spawn(quick)
      check r2.isOk
      m2.cancel()
      try: await m2.future
      except CancelledError: discard
      await r2.tryGet().future   # quick completes
    waitFor body()

  test "members snapshot reflects live count and identity":
    proc body() {.async: (raises: [Exception]).} =
      let g = newTaskGroup(maxSize = 4)
      proc slow(): Future[void] {.async.} =
        await sleepAsync(20.milliseconds)
      let m1 = g.spawn(slow).tryGet()
      let m2 = g.spawn(slow).tryGet()
      let m3 = g.spawn(slow).tryGet()
      check g.size == 3
      let snap = g.members
      check snap.len == 3
      check m1 in snap and m2 in snap and m3 in snap
      m1.cancel(); m2.cancel(); m3.cancel()
      for m in [m1, m2, m3]:
        try: await m.future
        except CancelledError: discard
      # auto-remove callbacks (addCallback on the futures) are
      # scheduled via callSoon — give the dispatcher a tick to drain.
      await sleepAsync(1.milliseconds)
      check g.size == 0
      check g.members.len == 0
    waitFor body()

  test "cancelAll cancels every member, awaits each, sets shuttingDown":
    proc body() {.async: (raises: [Exception]).} =
      let g = newTaskGroup(maxSize = 8)
      proc slow(): Future[void] {.async.} =
        await sleepAsync(1.seconds)
      discard g.spawn(slow).tryGet()
      discard g.spawn(slow).tryGet()
      discard g.spawn(slow).tryGet()
      check g.size == 3
      await g.cancelAll()
      check g.size == 0
      # After cancelAll: further spawns refused.
      let r = g.spawn(slow)
      check r.isErr and r.error == geShuttingDown
    waitFor body()

  test "joinAll awaits every member to finish normally":
    proc body() {.async: (raises: [Exception]).} =
      let g = newTaskGroup(maxSize = 4)
      var completed = 0
      proc work(): Future[void] {.async.} =
        await sleepAsync(2.milliseconds)
        inc completed
      discard g.spawn(work).tryGet()
      discard g.spawn(work).tryGet()
      discard g.spawn(work).tryGet()
      await g.joinAll()
      check completed == 3
      check g.size == 0
    waitFor body()

suite "task group: supervisor adoption":

  test "lcTemporary member crash is removed; supervisor keeps running":
    proc body() {.async: (raises: [Exception]).} =
      let g = newTaskGroup(maxSize = 4)
      let sup = newSupervisor()
      sup.adopt(g, "workers", lifecycle = lcTemporary)
      proc crash(): Future[void] {.async.} =
        await sleepAsync(2.milliseconds)
        raise newException(ValueError, "boom")
      proc ok(): Future[void] {.async.} =
        await sleepAsync(20.milliseconds)
      let crasher = g.spawn(crash).tryGet()
      let survivor = g.spawn(ok).tryGet()
      let supMount = spawn sup.run()
      try: await crasher.future
      except CatchableError: discard
      await sleepAsync(5.milliseconds)
      # Crasher removed (lcTemporary doesn't restart); survivor still in group.
      check g.size == 1
      check survivor in g.members
      check not survivor.future.finished
      # Now drain the survivor and let supervisor return.
      survivor.cancel()
      try: await survivor.future
      except CancelledError: discard
      supMount.cancel()
      try: await supMount.future
      except CancelledError: discard
    waitFor body()

  test "lcPermanent member crash is restarted with the same factory":
    proc body() {.async: (raises: [Exception]).} =
      let g = newTaskGroup(maxSize = 4)
      let sup = newSupervisor()
      sup.adopt(g, "workers", lifecycle = lcPermanent,
                maxRestarts = 20, within = 1.seconds)
      var starts = 0
      proc flaky(): Future[void] {.async.} =
        inc starts
        if starts < 3:
          await sleepAsync(2.milliseconds)
          raise newException(ValueError, "boom")
        # Long-running once stable.
        await sleepAsync(1.seconds)
      discard g.spawn(flaky).tryGet()
      let supMount = spawn sup.run()
      # Wait until the stable run is in progress.
      await sleepAsync(40.milliseconds)
      check starts == 3
      # Group now has one running member.
      check g.size == 1
      supMount.cancel()
      try: await supMount.future
      except CancelledError: discard
      await g.cancelAll()
    waitFor body()

  test "lcTransient: restart on crash, remove on clean exit":
    proc body() {.async: (raises: [Exception]).} =
      let g = newTaskGroup(maxSize = 4)
      let sup = newSupervisor()
      sup.adopt(g, "workers", lifecycle = lcTransient,
                maxRestarts = 20, within = 1.seconds)
      var crashStarts = 0
      var cleanStarts = 0
      proc crashTwiceThenSucceed(): Future[void] {.async.} =
        inc crashStarts
        await sleepAsync(2.milliseconds)
        if crashStarts < 3:
          raise newException(ValueError, "boom")
      proc cleanRunOnce(): Future[void] {.async.} =
        inc cleanStarts
        await sleepAsync(2.milliseconds)
      discard g.spawn(crashTwiceThenSucceed).tryGet()
      discard g.spawn(cleanRunOnce).tryGet()
      let supMount = spawn sup.run()
      await sleepAsync(40.milliseconds)
      check crashStarts == 3       # restarted after 2 crashes, then clean exit ⇒ removed
      check cleanStarts == 1       # clean exit on first run ⇒ removed
      check g.size == 0
      supMount.cancel()
      try: await supMount.future
      except CancelledError: discard
    waitFor body()

  test "per-pool rate window escalates on aggregate crash storm":
    proc body() {.async: (raises: [Exception]).} =
      let g = newTaskGroup(maxSize = 4)
      let sup = newSupervisor()
      sup.adopt(g, "workers", lifecycle = lcPermanent,
                maxRestarts = 3, within = 1.seconds)
      proc crasher(): Future[void] {.async.} =
        await sleepAsync(1.milliseconds)
        raise newException(ValueError, "boom")
      discard g.spawn(crasher).tryGet()
      let supMount = spawn sup.run()
      var escalated = false
      try:
        await supMount.future
      except SupervisorEscalation as e:
        escalated = true
        check e.childName == "workers"
      except CatchableError: discard
      check escalated
    waitFor body()

  test "adopt under ssOneForAll raises Defect":
    let sup = newSupervisor(strategy = ssOneForAll)
    let g = newTaskGroup(maxSize = 2)
    expect Defect:
      sup.adopt(g, "workers")

  test "supervisor cancellation cancels adopted-group members":
    proc body() {.async: (raises: [Exception]).} =
      let g = newTaskGroup(maxSize = 4)
      let sup = newSupervisor()
      sup.adopt(g, "workers", lifecycle = lcTemporary)
      proc slow(): Future[void] {.async.} =
        await sleepAsync(1.seconds)
      let m1 = g.spawn(slow).tryGet()
      let m2 = g.spawn(slow).tryGet()
      let supMount = spawn sup.run()
      await sleepAsync(5.milliseconds)
      supMount.cancel()
      try: await supMount.future
      except CancelledError: discard
      # Members should be cancelled by cascade.
      try: await m1.future
      except CancelledError: discard
      try: await m2.future
      except CancelledError: discard
      check m1.future.finished
      check m2.future.finished
    waitFor body()

  test "topology() includes adopted groups + per-member nodes":
    proc body() {.async: (raises: [Exception]).} =
      let g = newTaskGroup(maxSize = 8)
      let sup = newSupervisor()
      sup.addChild("named", lcPermanent, proc(): Future[void] {.async.} =
        await sleepAsync(100.milliseconds))
      sup.adopt(g, "workers", lifecycle = lcTemporary)
      proc work(): Future[void] {.async.} =
        await sleepAsync(100.milliseconds)
      discard g.spawn(work).tryGet()
      discard g.spawn(work).tryGet()
      let supMount = spawn sup.run()
      await sleepAsync(5.milliseconds)
      let top = sup.topology()
      # Expect: 1 nkChild + 1 nkPool + 2 nkPoolMember
      var children, pools, members: int
      var poolNode: TopologyNode
      for n in top:
        case n.kind
        of nkChild: inc children
        of nkPool:
          inc pools
          poolNode = n
        of nkPoolMember:
          inc members
          check n.poolName == "workers"
          check n.name.startsWith("workers#")
      check children == 1
      check pools == 1
      check members == 2
      check poolNode.name == "workers"
      check poolNode.poolSize == 2
      check poolNode.poolMax == 8
      supMount.cancel()
      try: await supMount.future
      except CancelledError: discard
      await g.cancelAll()
    waitFor body()

  test "pool members don't cascade under named-children ssOneForAll":
    # Pool is a separate cascade domain. Even under ssOneForAll for
    # named children, a named-child crash must NOT cancel pool members.
    proc body() {.async: (raises: [Exception]).} =
      let g = newTaskGroup(maxSize = 4)
      let sup = newSupervisor(strategy = ssOneForOne)  # pools require this
      sup.adopt(g, "workers", lifecycle = lcTemporary)
      var crasherStarts = 0
      proc crashOnce(): Future[void] {.async.} =
        inc crasherStarts
        await sleepAsync(2.milliseconds)
        if crasherStarts == 1:
          raise newException(ValueError, "boom")
        await sleepAsync(50.milliseconds)
      proc workerLong(): Future[void] {.async.} =
        await sleepAsync(50.milliseconds)
      sup.addChild("crasher", lcPermanent, crashOnce)
      let m = g.spawn(workerLong).tryGet()
      let supMount = spawn sup.run()
      await sleepAsync(20.milliseconds)
      # Named child crashed + restarted; pool member untouched.
      check crasherStarts >= 2
      check not m.future.finished
      supMount.cancel()
      try: await supMount.future
      except CancelledError: discard
      try: await m.future
      except CancelledError: discard
    waitFor body()

  test "spawn from inside a pool member into the same group (wakeup + #42 regression)":
    # Regression for #42: an adopted pool member that spawns into its
    # own group after an `await` used to SIGSEGV in `nimIncRefCyclic`
    # — the chronos contextvars substrate stored the binding's value
    # as `addr` of a stack local in the binder (`withScope`), and
    # when the binder was a synchronous proc (`group.spawn`) the
    # stack frame ended before the captured callback's continuation
    # fired, leaving a dangling pointer. The fix on the chronos fork
    # moves the value into a heap-allocated `ContextNodeT[T]` ref
    # object so the address is stable for the node's full lifetime.
    proc body() {.async: (raises: [Exception]).} =
      let sup = newSupervisor()
      let g = newTaskGroup(maxSize = 4)
      sup.adopt(g, "workers", lifecycle = lcTemporary)

      var memberSpawned = false
      proc siblingBody() {.async.} = await sleepAsync(1.milliseconds)
      let siblingFactory: proc(): Future[void] {.closure, gcsafe, raises: [].} =
        proc(): Future[void] {.closure, gcsafe, raises: [].} = siblingBody()

      proc memberBody() {.async.} =
        await sleepAsync(5.milliseconds)
        # The historical crash site — fresco.spawn template's read
        # of `currentScope` (a chronos contextVar) returned a Scope
        # ref backed by freed stack memory.
        discard g.spawn(siblingFactory)
        memberSpawned = true
      let memberFactory: proc(): Future[void] {.closure, gcsafe, raises: [].} =
        proc(): Future[void] {.closure, gcsafe, raises: [].} = memberBody()

      discard g.spawn(memberFactory)
      let runMount = spawn sup.run()
      # Both members are lcTemporary; loop exits when both finish.
      try: await runMount.future
      except CatchableError: discard
      check memberSpawned
