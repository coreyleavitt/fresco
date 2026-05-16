## Cross-module compile-time capability discharge (#53).
##
## Empirically: module-scoped `{.compileTime.}` vars in Nim are
## shared across the compilation unit (not per-importer), so the
## `{.needs.}` static blocks in dependency modules populate the same
## `procRequiresTable` that downstream `staticSupervisor:` macros
## query. This file pins that behavior so a future Nim/macro refactor
## that breaks cross-module CT sharing turns red here.

import std/unittest
import fresco/reactive/capabilities
import fresco/reactive/capset
import xmodule_tasks_a
import xmodule_tasks_b
import xmodule_user_caps_a
import xmodule_user_caps_b

suite "cross-module discharge":

  test "task in module A, supervisor in this module, provides cap → compiles":
    let sup = staticSupervisor:
      provides(FsReadCap)
      child fsTaskA              # declared in xmodule_tasks_a.nim
    check sup != nil

  test "task in module A, supervisor missing cap → compile error":
    check not compiles(
      block:
        let sup = staticSupervisor:
          provides(NetworkCap)   # missing FsReadCap for fsTaskA
          child fsTaskA
        sup)

  test "tasks from two different modules compose in one supervisor":
    let sup = staticSupervisor:
      provides(FsReadCap, NetworkCap, ProcessCap, TerminalCap)
      child fsTaskA              # module A
      child netTaskA             # module A
      child procTaskB            # module B
      child termTaskB            # module B
    check sup != nil

  test "multi-source negative: missing one cross-module cap → error":
    check not compiles(
      block:
        let sup = staticSupervisor:
          provides(FsReadCap, ProcessCap)
          # NetworkCap and TerminalCap missing
          child fsTaskA           # A — covered
          child netTaskA          # A — uncovered
          child procTaskB         # B — covered
          child termTaskB         # B — uncovered
        sup)

  test "task with combined caps from module A discharges across modules":
    let sup = staticSupervisor:
      provides(FsReadCap, NetworkCap)
      child bothTaskA             # needs both, both provided
    check sup != nil

## Module-level user-cap registration for the slot-allocator
## cross-module check. The build succeeding (this module loaded
## without "type ... is already registered") is the regression:
## without the signatureHash-based dedup, `LocalCap` here would
## have collided with the same-named types in xmodule_user_caps_*.
type LocalCap = ref object
registerCap LocalCap

suite "cross-module discharge: user-cap slot allocator":

  test "registerCap in different modules with the same short type name doesn't false-collide":
    # Two distinct types named `MyCap` are defined and registered
    # via `xmodule_user_caps_a` and `xmodule_user_caps_b` (loaded
    # below). Plus `LocalCap` at this module's top level. All
    # claim distinct slots — verified by the build succeeding.
    # signatureHash makes the dedup key globally unique; without
    # it, T.repr-based dedup would have tripped on the duplicate
    # name.
    check capKindFor(LocalCap).ord >= ord(ckUser0)
