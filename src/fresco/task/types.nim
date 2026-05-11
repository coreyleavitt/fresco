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

  MountCollector* = ref object
    ## Heap-allocated collector for `parallel:` blocks. Holding it as a
    ## ref (not a raw pointer to a stack-allocated seq) means we can
    ## safely carry it through CLS save/restore around awaits without
    ## the pointer dangling if the surrounding stack frame moves.
    mounts*: seq[Mount]

var parallelCollector* {.threadvar.}: MountCollector
  ## When non-nil, any `spawn` adds its Mount to `collector.mounts` so
  ## a `parallel:` block can await them as a group. Lifetime-scoped by
  ## the `parallel` template; do not touch directly.
