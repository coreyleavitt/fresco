## Task type primitives — pure data, no async machinery.
##
## Separated from `core.nim` so low-level modules can reach `Mount` /
## `MountCollector` / `parallelCollector` without dragging in the full
## task lifecycle machinery (spawn, wireLifecycle, journal-write
## boilerplate).

import chronos
import chronos/contextvars
import ../reactive/scope

type
  Mount* = ref object
    scope*: Scope
    future*: Future[void]
    name*: string
      ## The call expression that produced this Mount (e.g. "worker()"),
      ## captured by `spawn` via `astToStr(call)`. Mirrors what the
      ## journal stores in `ekTaskSpawned.spawnedName` but is reachable
      ## from a live Mount without a journal query. Used by `parallel:`
      ## for concurrent-failure naming.

  ChildFactory* = proc(): Future[void] {.closure, gcsafe, raises: [].}
    ## Reusable spawn closure: invokes the underlying async proc each
    ## time it's called. Supervisor and TaskGroup both use this shape
    ## (closures capture per-call args; the factory itself takes none).

  MountCollector* = ref object
    ## Heap-allocated collector for `parallel:` blocks. Holding it as a
    ## ref (not a raw pointer to a stack-allocated seq) means we can
    ## safely carry it through CLS save/restore around awaits without
    ## the pointer dangling if the surrounding stack frame moves.
    mounts*: seq[Mount]

contextVar:
  var parallelCollector: MountCollector = nil
  ## Backed by chronos's continuation-local storage so the binding
  ## propagates through `await`. Read as `parallelCollector`, bind
  ## via `withParallelCollector(c): body`. The `parallel:` and
  ## `spawn` templates handle this internally; user code doesn't
  ## interact with it directly.
