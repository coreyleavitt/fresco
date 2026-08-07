## Grant-token injection + currentSup accessor (deferred from #72).
##
## `{.needs.}` now rewrites the proc body to prepend per-cap `grant`
## template overloads and a typed `currentSup()` accessor. Inside the
## body:
##
##   - `grant(FsReadCap)` returns a `FsReadGrant` value
##   - `grant(<cap not in needs>)` is a compile error (no matching overload)
##   - `currentSup()` returns an Option[<synthetic ProcSup>] whose type
##     satisfies every `Grants*` concept the proc's needs declared

import std/unittest
import chronos
include intonaco/reactive_internal
import ./xmodule_concept_caps

suite "grant injection: per-cap overload inside task body":

  test "{.needs: FsReadCap.} injects grant(FsReadCap): FsReadGrant":
    proc t() {.needs: FsReadCap.} =
      let g = grant(FsReadCap)
      check g is FsReadGrant
    t()

  test "grant(undeclared cap) inside body → compile error":
    check not compiles(
      block:
        proc bad() {.needs: FsReadCap.} =
          discard grant(NetworkCap)    # NetworkCap not in needs
        bad())

  test "multi-cap {.needs: (A, B).} injects both grant overloads":
    proc t() {.needs: (FsReadCap, NetworkCap).} =
      let g1 = grant(FsReadCap)
      let g2 = grant(NetworkCap)
      check g1 is FsReadGrant
      check g2 is NetworkGrant
    t()

suite "currentSup: typed supervisor accessor inside task":

  test "currentSup() inside a supervisor-spawned task returns the supervisor":
    var seenNonNil = false
    proc captureTask(): Future[void] {.async: (raises: [CatchableError]),
                                       needs: FsReadCap.} =
      let s = currentSup()
      if s.isSome: seenNonNil = true

    proc body() {.async: (raises: [Exception]).} =
      let sup = supervisor:
        provides(FsReadCap)
        child captureTask
      let m = spawn sup.run()
      await sleepAsync(20.milliseconds)
      m.cancel()
    waitFor body()
    check seenNonNil

  test "currentSup() in a non-supervisor-spawned proc returns none":
    var sawNone = false
    proc lonelyTask() {.needs: FsReadCap.} =
      # Called directly, not from a supervisor — contextVar is nil.
      let s = currentSup()
      if s.isNone: sawNone = true
    lonelyTask()
    check sawNone

  test "cross-module library helper accepts currentSup().get":
    var helperRan = false
    proc usesSup(): Future[void] {.async: (raises: [CatchableError]),
                                   needs: CrossModCap.} =
      let s = currentSup()
      if s.isSome:
        # The typed currentSup gives back a supervisor whose type
        # satisfies GrantsCrossModCap, so the cross-module helper's
        # [S: GrantsCrossModCap] constraint accepts it at the call site.
        discard helperNeedingCrossMod(s.get)
        helperRan = true

    proc body() {.async: (raises: [Exception]).} =
      let sup = supervisor:
        provides(CrossModCap)
        child usesSup
      helperCalls = 0
      let m = spawn sup.run()
      await sleepAsync(20.milliseconds)
      m.cancel()
    waitFor body()
    check helperRan
    check helperCalls >= 1

  test "currentSup() survives across await — chronos contextVar property":
    var sameSupervisor = false
    proc awaitTask(): Future[void] {.async: (raises: [CatchableError]),
                                     needs: FsReadCap.} =
      let before = currentSup()
      await sleepAsync(2.milliseconds)
      let after = currentSup()
      if before.isSome and after.isSome and
         cast[pointer](before.get) == cast[pointer](after.get):
        sameSupervisor = true

    proc body() {.async: (raises: [Exception]).} =
      let sup = supervisor:
        provides(FsReadCap)
        child awaitTask
      let m = spawn sup.run()
      await sleepAsync(20.milliseconds)
      m.cancel()
    waitFor body()
    check sameSupervisor

  test "restart re-seeds currentSup with the same supervisor instance":
    # On restart, the supervisor.run() loop calls factory() again from
    # within `withCurrentSupervisor(s):`. The chronos context capture
    # at re-spawn must use the same `s`, so the restarted task body
    # sees identical currentSup pointer.
    var runs = 0
    var firstP: pointer = nil
    var allSame = true
    proc flakyTask(): Future[void] {.async: (raises: [CatchableError]),
                                     needs: FsReadCap.} =
      let s = currentSup()
      if s.isSome:
        let p = cast[pointer](s.get)
        if runs == 0: firstP = p
        elif p != firstP: allSame = false
        inc runs
      await sleepAsync(2.milliseconds)

    proc body() {.async: (raises: [Exception]).} =
      let sup = supervisor:
        provides(FsReadCap)
        child flakyTask                # lcPermanent → restarts on clean exit
      let m = spawn sup.run()
      await sleepAsync(30.milliseconds)
      m.cancel()
    waitFor body()
    check runs >= 2          # restart happened at least once
    check allSame

suite "grant injection: {.inferCaps.} composes":

  test "{.inferCaps.} injects grants for inferred caps":
    proc loadAndUse() {.inferCaps.} =
      # inferCaps detects readFile → FsReadCap
      discard readFile("/tmp/nope")
      # Should be able to ask for the inferred cap's grant
      let g = grant(FsReadCap)
      check g is FsReadGrant
    # Not actually running — we just want the compile to succeed.
    when not compiles(loadAndUse): check false
    check true
