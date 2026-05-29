## Cross-module compile-time capability discharge.
##
## Empirically: module-scoped `{.compileTime.}` vars in Nim are
## shared across the compilation unit (not per-importer), so the
## `{.needs.}` pragma in dependency modules populates the same
## `procRequiresNames` store that downstream `supervisor:`
## macros query. This file pins that behavior so a future Nim/macro
## refactor that breaks cross-module CT sharing turns red here.
##
## Cross-module **user-cap** discharge is covered in test_capconcept's
## "cross-module user-cap discharge" suite (uses `cap T` instead of
## the retired `registerCap`).

import std/unittest
import intonaco/reactive
import xmodule_tasks_a
import xmodule_tasks_b

suite "cross-module discharge":

  test "task in module A, supervisor in this module, provides cap → compiles":
    let sup = supervisor:
      provides(FsReadCap)
      child fsTaskA              # declared in xmodule_tasks_a.nim
    check sup != nil

  test "task in module A, supervisor missing cap → compile error":
    check not compiles(
      block:
        let sup = supervisor:
          provides(NetworkCap)   # missing FsReadCap for fsTaskA
          child fsTaskA
        sup)

  test "tasks from two different modules compose in one supervisor":
    let sup = supervisor:
      provides(FsReadCap, NetworkCap, ProcessCap, TerminalCap)
      child fsTaskA              # module A
      child netTaskA             # module A
      child procTaskB            # module B
      child termTaskB            # module B
    check sup != nil

  test "multi-source negative: missing one cross-module cap → error":
    check not compiles(
      block:
        let sup = supervisor:
          provides(FsReadCap, ProcessCap)
          # NetworkCap and TerminalCap missing
          child fsTaskA           # A — covered
          child netTaskA          # A — uncovered
          child procTaskB         # B — covered
          child termTaskB         # B — uncovered
        sup)

  test "task with combined caps from module A discharges across modules":
    let sup = supervisor:
      provides(FsReadCap, NetworkCap)
      child bothTaskA             # needs both, both provided
    check sup != nil

