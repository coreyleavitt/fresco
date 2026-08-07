## test_intonaco_idle_reachable.nim — RFC headless-quiescence slice B5: pin
## bump reachability probe.
##
## intonaco A1/A2 added `reactiveIdle`, `reactivePendingCount`, and
## `animationsIdle` to the substrate (scheduler.nim / animation.nim). Their
## semantics are already covered by intonaco's own black-box tests
## (test_scheduler_idle.nim, test_animation_idle.nim) — this probe only
## proves the accessors are reachable from fresco's side of the pin, through
## the public `import intonaco/reactive` re-export chain (per RFC Design 1/2
## verification note), and hold at rest.

import std/unittest
import intonaco/reactive

suite "B5: intonaco idle accessors reachable from fresco":

  test "reactiveIdle, reactivePendingCount, and animationsIdle all hold at rest":
    check reactiveIdle()
    check reactivePendingCount() == 0
    check animationsIdle()
