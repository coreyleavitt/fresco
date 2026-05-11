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
import ./cls

proc awaitParallel(mounts: seq[Mount]) {.task, async: (raises: [CatchableError]).} =
  ## Wait for every Mount. On first failure: cancel siblings, drain
  ## their cancellation cascades, re-raise the original error.
  var pending = mounts
  while pending.len > 0:
    var futs: seq[FutureBase] = @[]
    for m in pending: futs.add m.future.FutureBase
    let winner = await race(futs)
    var idx = -1
    for i, m in pending:
      if m.future.FutureBase == winner: idx = i; break
    if idx < 0:
      # race() returned a future we don't recognize — should not
      # happen since we pass it exactly the pending mounts' futures,
      # but defend against chronos race quirks rather than crash.
      continue
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
    var mounts: seq[Mount] = @[]
    let prev = parallelCollector
    parallelCollector = addr mounts
    try:
      body
    finally:
      parallelCollector = prev
    if mounts.len > 0:
      await awaitParallel(mounts)
