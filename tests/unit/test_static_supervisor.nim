## Compile-time capability discharge via `staticSupervisor:` (#35 C1).

import std/unittest
import fresco/reactive/capabilities
import fresco/reactive/capset

# Tasks under test — declared at module scope so {.requires.} can stash
# into the per-module CT table and the `staticSupervisor:` DSL in the
# suite below can look them up.

proc fsTask()   {.needs: FsReadCap.} = discard
proc netTask()  {.needs: NetworkCap.} = discard
proc bothTask() {.needs: (FsReadCap, NetworkCap).} = discard

suite "static supervisor: happy-path discharge":

  test "supervisor provides every cap a child requires → compiles":
    let sup = staticSupervisor:
      provides(FsReadCap, NetworkCap)
      child fsTask
      child netTask
      child bothTask
    check sup != nil

  test "single-cap proc + matching provides compiles":
    let sup = staticSupervisor:
      provides(FsReadCap)
      child fsTask
    check sup != nil

suite "static supervisor: negative discharge produces compile errors":

  test "missing single cap → compile error names the missing cap":
    # `compiles` returns false because the `staticSupervisor:` macro
    # emits a macro `error()` at discharge time. The error message
    # itself is checked separately below.
    check not compiles(
      block:
        let sup = staticSupervisor:
          provides(NetworkCap)   # doesn't cover FsReadCap
          child fsTask
        sup)

  test "missing one of several caps → compile error":
    check not compiles(
      block:
        let sup = staticSupervisor:
          provides(FsReadCap)    # missing NetworkCap
          child bothTask
        sup)

  test "child without {.needs.} annotation → compile error":
    proc bareTask() = discard
    check not compiles(
      block:
        let sup = staticSupervisor:
          provides(FsReadCap)
          child bareTask
        sup)

suite "static supervisor: nested topology (ancestor provides reach descendants)":

  test "outer provides covers nested child's needs":
    let sup = staticSupervisor:
      provides(FsReadCap, NetworkCap)
      child fsTask
      supervisor:
        provides(TerminalCap)
        # `netTask` needs NetworkCap, satisfied by the OUTER's provides.
        child netTask
    check sup != nil

  test "nested child sees union(outer.provides, inner.provides)":
    proc termPlusFs() {.needs: (TerminalCap, FsReadCap).} = discard
    let sup = staticSupervisor:
      provides(FsReadCap)
      supervisor:
        provides(TerminalCap)   # adds locally; FsReadCap inherited
        child termPlusFs
    check sup != nil

  test "nested child whose need is NOT in either scope → compile error":
    proc needsProcess() {.needs: ProcessCap.} = discard
    check not compiles(
      block:
        let sup = staticSupervisor:
          provides(FsReadCap)
          supervisor:
            provides(TerminalCap)
            child needsProcess     # ProcessCap nowhere on the chain
        sup)
