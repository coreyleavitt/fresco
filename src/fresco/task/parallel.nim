## Structured concurrency: a `parallel:` block awaits every `spawn`
## inside it as a group. If any child raises, the remaining are
## cancelled and the exception propagates.
##
##   await parallel:
##     spawn taskA()
##     spawn taskB()
##     spawn taskC()
##
## Semantics mirror Kotlin coroutines `coroutineScope` and Trio's
## `async with trio.open_nursery()`. The block returns when all
## children return normally; if a child raises, the cancellation
## cascades synchronously to its siblings before the exception bubbles
## out of the block.

import chronos
import ./core
import ../cls
import ../journal/events as jev
import ../journal/log

proc awaitParallel(mounts: seq[Mount]) {.task, async: (raises: [CatchableError]).} =
  ## Wait for every Mount. On first failure: cancel siblings, drain
  ## their cancellation cascades, re-raise the original error.
  ##
  ## `{.task.}` is required: the sibling-failure journaling inside the
  ## drain loop reads `currentScope` via `journalEvent`, and that
  ## must survive the `await race(futs)` suspensions.
  var pending = mounts
  while pending.len > 0:
    var futs: seq[FutureBase] = @[]
    for m in pending: futs.add m.future.FutureBase
    let winner = await race(futs)
    var idx = -1
    for i, m in pending:
      if m.future.FutureBase == winner: idx = i; break
    # race() should always return one of the futures we passed in. If
    # it ever doesn't, falling through to `continue` would infinite-
    # loop on the same unmatched winner — fail loudly instead.
    doAssert idx >= 0, "awaitParallel: race() returned unknown future"
    let completed = pending[idx]
    pending.del(idx)
    if completed.future.failed:
      let rawErr = completed.future.error
      # chronos rarely marks a Future failed before attaching its
      # error ref. `raise nil` would crash without a useful trace —
      # synthesize a placeholder so the cascade still propagates.
      let err =
        if rawErr != nil: rawErr
        else: (ref CatchableError)(msg: "task failed without error",
                                    name: "CatchableError")
      for p in pending:
        if not p.future.finished: p.cancel()
      for p in pending:
        try: await p.future
        except CancelledError:
          # We just cancelled this sibling — expected, not a failure.
          discard
        except CatchableError as siblingErr:
          # Sibling crashed concurrently with the winner. Journal it
          # under the sibling's OWN scope (not the parallel block's
          # enclosing scope) — that's how supervisor.nim:240 handles
          # the analogous case, and it makes `byTask(siblingTaskId)`
          # actually find the event. Direct log call rather than
          # `journalEvent` because that template uses currentScope,
          # which is the parallel's enclosing task here.
          if siblingErr != nil and globalJournal != nil:
            let siblingTid = p.scope.taskId
            let siblingParent = p.scope.lastEventId
            let siblingName = "parallel-task-" & $siblingTid
            let reason = "concurrent failure during parallel cascade: " & siblingErr.msg
            try:
              let id = globalJournal.logSupervisorEscalate(
                siblingTid, siblingParent, siblingName, reason)
              p.scope.lastEventId = id
            except CatchableError: discard
      raise err

template parallel*(body: untyped): untyped =
  ## All `spawn`s inside `body` are awaited as a group. If any raises,
  ## the remaining are cancelled and the exception propagates. Must be
  ## called from an async context.
  ##
  ## **Awaiting inside the parallel body is safe** as long as the
  ## enclosing async proc is annotated `{.task.}` — fresco's CLS
  ## substrate restores `parallelCollector` after every suspension,
  ## so spawns from sibling coroutines that run during the suspension
  ## don't end up joined to this group. Without `{.task.}` on the
  ## enclosing proc, an interleaved `spawn` from another coroutine
  ## would incorrectly land in our collector.
  block:
    let collector = MountCollector()
    let prev = parallelCollector
    parallelCollector = collector
    try:
      body
    finally:
      parallelCollector = prev
    if collector.mounts.len > 0:
      # `taskAwait` (not bare `await`) — this await is emitted at
      # template-expansion time, after the enclosing proc's `{.task.}`
      # pragma has already walked the body, so task's rewriter never
      # sees it. Without explicit CLS wrapping, `currentScope` and
      # `currentSpeculative` after the parallel block would be
      # whatever the dispatcher last left them as.
      taskAwait awaitParallel(collector.mounts)
