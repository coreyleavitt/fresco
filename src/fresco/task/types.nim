## Task type primitives — pure data, no async machinery.
##
## Separated from `core.nim` so that `cls.nim` (layer-0 CLS substrate)
## can import these types without dragging in the full task lifecycle
## machinery (spawn, wireLifecycle, journal-write boilerplate). cls
## needs `MountCollector` and the `parallelCollector` threadvar for
## context capture; that's it.

import chronos
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

  MountCollector* = ref object
    ## Heap-allocated collector for `parallel:` blocks. Holding it as a
    ## ref (not a raw pointer to a stack-allocated seq) means we can
    ## safely carry it through CLS save/restore around awaits without
    ## the pointer dangling if the surrounding stack frame moves.
    mounts*: seq[Mount]

var parallelCollector* {.threadvar.}: MountCollector
  ## INTERNAL: exported only so cls.nim's TaskContext can carry it
  ## through CLS save/restore, and so the parallel: template and
  ## spawn template can read/write it. Test code that needs to
  ## introspect (e.g. assert collector.mounts.len) imports this
  ## module directly. **Do not modify from user code.**
