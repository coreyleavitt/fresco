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

proc awaitParallel(mounts: seq[Mount]) {.async: (raises: [CatchableError]).} =
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
    let completed = pending[idx]
    pending.del(idx)
    if completed.future.failed:
      let err = completed.future.error
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
  ## **Constraint:** `body` should consist of `spawn` calls without
  ## intervening `await`s. The block uses a thread-local pointer to
  ## collect spawned Mounts; if `body` awaits, another coroutine that
  ## runs during the suspension and calls `spawn` will have its Mount
  ## added to *this* group, joining its lifetime to ours and causing
  ## cross-task cancellation on failure.
  ##
  ## If you need to interleave awaits with spawns, await the
  ## individual Mounts explicitly with `m.wait()` and skip `parallel:`.
  ## v3 fix tracked at github issue #37 (coroutine-context isolation).
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
