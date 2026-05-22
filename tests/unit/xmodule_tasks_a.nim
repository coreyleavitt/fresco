## Helper module A for the cross-module discharge characterization
## test (#53). Defines tasks with `{.needs.}` annotations to be
## consumed by a `supervisor:` in a different module.

import intonaco/reactive/capabilities

proc fsTaskA*() {.needs: FsReadCap.} = discard

proc netTaskA*() {.needs: NetworkCap.} = discard

proc bothTaskA*() {.needs: (FsReadCap, NetworkCap).} = discard
