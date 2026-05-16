## Cross-module same-name dedup helper A.
## Defines a `MyCap` and registers it; xmodule_user_caps_b does
## the same with a distinct-but-same-named type. The build
## succeeding when both are imported proves registerCap's dedup
## doesn't false-collide on short type name (#53).

import fresco/reactive/capabilities

type MyCap* = ref object
registerCap MyCap
