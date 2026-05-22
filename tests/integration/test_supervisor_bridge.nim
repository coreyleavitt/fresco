## Static↔runtime supervisor bridge (#72).
##
## The unified `supervisor:` macro replaces both `staticSupervisor:`
## (compile-time cap discharge only) and the old `supervisor name:`
## (runtime supervision only) — one construct that does both. Children
## declared via `child` are actually spawned by `await sup.run()`.

import std/unittest
import chronos
import intonaco/reactive/capabilities
import intonaco/task/core
import intonaco/task/supervisor
import ../unit/xmodule_concept_caps

suite "supervisor bridge: tracer — declared children actually run":

  test "anonymous supervisor: spawns a child when sup.run() is awaited":
    var ran = 0
    proc traceTask(): Future[void] {.async: (raises: [CatchableError]),
                                     needs: FsReadCap.} =
      inc ran

    proc body() {.async: (raises: [Exception]).} =
      let sup = supervisor:
        provides(FsReadCap)
        child traceTask
      let m = spawn sup.run()
      await sleepAsync(20.milliseconds)
      m.cancel()
    waitFor body()
    check ran >= 1

  test "returned value satisfies the Grants* concept for each provided cap":
    proc t1() {.async: (raises: [CatchableError]), needs: FsReadCap.} =
      discard

    let sup = supervisor:
      provides(FsReadCap, NetworkCap)
      child t1
    static:
      doAssert typeof(sup) is GrantsFsReadCap
      doAssert typeof(sup) is GrantsNetworkCap
    check sup is Supervisor    # Inherits from runtime Supervisor base

  test "missing cap → hard compile error at the child line":
    proc needsNet() {.async: (raises: [CatchableError]),
                      needs: NetworkCap.} = discard
    check not compiles(
      block:
        let sup = supervisor:
          provides(FsReadCap)         # NetworkCap not provided
          child needsNet
        sup)

  test "`child factory, lcTransient` comma form overrides lifecycle":
    # Design note: chose comma syntax over colon — `child f: lc` AST
    # wraps the lifecycle in a StmtList (awkward to consume in the
    # macro) whereas `child f, lc` is a clean three-child Command.
    var starts = 0
    proc transientTask(): Future[void] {.async: (raises: [CatchableError]),
                                         needs: FsReadCap.} =
      inc starts
      await sleepAsync(2.milliseconds)

    proc body() {.async: (raises: [Exception]).} =
      let sup = supervisor:
        provides(FsReadCap)
        child transientTask, lcTransient
      let m = spawn sup.run()
      await sleepAsync(30.milliseconds)
      m.cancel()
    waitFor body()
    # lcTransient: runs once, completes cleanly, no restart.
    check starts == 1

  test "`child(name, lifecycle, factory)` paren back-compat form":
    var starts = 0
    proc explicitTask(): Future[void] {.async: (raises: [CatchableError]),
                                        needs: FsReadCap.} =
      inc starts
      await sleepAsync(2.milliseconds)

    var sawName = false
    proc body() {.async: (raises: [Exception]).} =
      let sup = supervisor:
        provides(FsReadCap)
        child("renamedTask", lcTemporary, explicitTask)
      # Topology immediately after construction (pre-run) — name is
      # the explicit string from the paren form, not the factory ident.
      for n in sup.topology():
        if n.name == "renamedTask": sawName = true
      let m = spawn sup.run()
      await sleepAsync(20.milliseconds)
      m.cancel()
    waitFor body()
    check sawName
    # lcTemporary: never restart.
    check starts == 1

suite "supervisor bridge: named form":

  test "`supervisor appSup:` declares appSup with caps + runs children":
    var ran = 0
    proc namedTask(): Future[void] {.async: (raises: [CatchableError]),
                                     needs: FsReadCap.} =
      inc ran

    proc body() {.async: (raises: [Exception]).} =
      supervisor appSup:
        provides(FsReadCap)
        child namedTask
      static:
        doAssert typeof(appSup) is GrantsFsReadCap
      check appSup is Supervisor
      let m = spawn appSup.run()
      await sleepAsync(20.milliseconds)
      m.cancel()
    waitFor body()
    check ran >= 1

suite "supervisor bridge: config assignments":

  test "maxRestarts + within propagate to the runtime supervisor":
    proc body() {.async: (raises: [Exception]).} =
      let sup = supervisor:
        maxRestarts = 42
        within      = 7.seconds
        strategy    = ssOneForAll
      check sup.maxRestarts == 42
      check sup.within      == 7.seconds
      check sup.strategy    == ssOneForAll
    waitFor body()

suite "supervisor bridge: cross-module library helper still works":

  test "concept-constrained helper accepts the unified supervisor":
    let sup = supervisor:
      provides(CrossModCap)
    helperCalls = 0
    discard helperNeedingCrossMod(sup)   # declared in xmodule_concept_caps
    check helperCalls == 1
    # Supervisor inheritance preserves the runtime base.
    check sup is Supervisor

  test "supervisor missing the helper's cap → compile error at the call site":
    let sup = supervisor:
      provides(FsReadCap)               # CrossModCap not granted
    check not compiles(helperNeedingCrossMod(sup))
