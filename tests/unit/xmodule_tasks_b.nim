## Helper module B for cross-module discharge characterization (#53).
## Distinct from xmodule_tasks_a — used together to verify that a
## supervisor in a third module can compose tasks declared across
## two separate dependency modules.

import fresco/reactive/capabilities

proc procTaskB*() {.needs: ProcessCap.} = discard

proc termTaskB*() {.needs: TerminalCap.} = discard
