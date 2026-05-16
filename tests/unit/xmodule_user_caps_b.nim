## Sibling of xmodule_user_caps_a — distinct `MyCap` type with
## the same short name. The registerCap call here would have
## collided under the old T.repr-based dedup; signatureHash keys
## the dedup by the type's Sym identity instead.

import fresco/reactive/capabilities

type MyCap* = ref object
registerCap MyCap
