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
import ../journal/events   # for `$` on TaskId
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
          # enclosing scope) so `byTask(siblingTaskId)` finds it.
          # `journalEventOnScope` is the cross-cutting helper for
          # this pattern (same one wireLifecycle uses).
          if siblingErr != nil:
            # Mount carries the original `astToStr(call)` name (set by
            # `spawn`), so the journal entry identifies the exact
            # call expression that failed — not a synthetic placeholder.
            let siblingName =
              if p.name.len > 0: p.name
              else: "parallel-task-" & $p.scope.taskId
            let reason = "concurrent failure during parallel cascade: " & siblingErr.msg
            journalEventOnScope(p.scope):
              jrnl.logSupervisorEscalate(taskTid, parentEvt, siblingName, reason)
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
    var bodyRaised = false
    try:
      body
    except CatchableError:
      bodyRaised = true
      # Body raised after some spawns may have registered. Structured
      # concurrency: cancel everything that was started, then re-raise
      # so the caller sees the original failure. Cancellation is
      # async (cancelSoon) — the spawned mounts' wireLifecycle
      # callbacks will dispose their scopes when the futures finally
      # resolve as cancelled. We don't await here (async-in-finally
      # is unsafe under chronos); we only need the cancellation
      # request issued before unwinding.
      for m in collector.mounts:
        if not m.future.finished: m.cancel()
      parallelCollector = prev
      raise
    finally:
      if not bodyRaised:
        parallelCollector = prev
    if collector.mounts.len > 0:
      # `taskAwait` (not bare `await`) — this await is emitted at
      # template-expansion time, after the enclosing proc's `{.task.}`
      # pragma has already walked the body, so task's rewriter never
      # sees it. Without explicit CLS wrapping, `currentScope` and
      # `currentSpeculative` after the parallel block would be
      # whatever the dispatcher last left them as.
      taskAwait awaitParallel(collector.mounts)
