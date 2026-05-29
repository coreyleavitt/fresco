## Concept-based capability discharge (μb rewrite).
##
## The user-facing surface — `{.needs.}` pragma and `supervisor:`
## DSL — is unchanged. What's different is the *encoding*: caps are
## structural grant fields on the supervisor's object type, and
## discharge is checked via concept satisfaction rather than CT bitmap
## subset. These tests verify the new substrate's observable properties
## without leaking encoding details.

import std/unittest
import intonaco/reactive
import xmodule_concept_caps

# User caps for the `cap T` suite below. Must be declared at top level
# because `cap` emits `*`-exported types and the cap's identity must
# be globally visible to every `supervisor:` and `{.needs.}` site
# that mentions it.
cap MyAppCap
cap MyOtherCap
cap MyThirdCap

suite "capconcept: tracer — concept-typed discharge end-to-end":

  test "supervisor whose provides(X) matches a child's {.needs: X.} carries the Grants concept for X":
    proc tracerTask() {.needs: FsReadCap.} = discard
    let sup = supervisor:
      provides(FsReadCap)
      child tracerTask
    # The supervisor's type structurally carries an FsReadCap grant.
    # Concept satisfaction is the new discharge primitive — this assertion
    # at compile time is the whole point of the rewrite.
    static:
      doAssert typeof(sup) is GrantsFsReadCap
    check sup != nil

  test "supervisor missing a cap does NOT satisfy the Grants concept for that cap":
    proc fsOnly() {.needs: FsReadCap.} = discard
    let sup = supervisor:
      provides(FsReadCap)
      child fsOnly
    static:
      doAssert typeof(sup) is GrantsFsReadCap
      doAssert not (typeof(sup) is GrantsNetworkCap)

  test "negative discharge: child needing a cap not in provides → compile error":
    proc needsNet() {.needs: NetworkCap.} = discard
    check not compiles(
      block:
        let sup = supervisor:
          provides(FsReadCap)        # NetworkCap not provided
          child needsNet
        sup)

suite "capconcept: multi-cap conjunction (A∧B)":

  test "supervisor providing A and B satisfies both concepts simultaneously":
    proc bothTask() {.needs: (FsReadCap, NetworkCap).} = discard
    let sup = supervisor:
      provides(FsReadCap, NetworkCap)
      child bothTask
    static:
      doAssert typeof(sup) is GrantsFsReadCap
      doAssert typeof(sup) is GrantsNetworkCap
      doAssert typeof(sup) is (GrantsFsReadCap and GrantsNetworkCap)
    check sup != nil

  test "supervisor providing only A fails to discharge child needing A and B":
    proc bothTask2() {.needs: (FsReadCap, NetworkCap).} = discard
    check not compiles(
      block:
        let sup = supervisor:
          provides(FsReadCap)        # NetworkCap missing
          child bothTask2
        sup)

suite "capconcept: order independence":

  test "provides(A,B) and provides(B,A) discharge the same child":
    # Free property: concept satisfaction is structural by member-name,
    # not by declaration order. Two supervisors built from `provides`
    # lines in different orders satisfy the same set of `Grants*`
    # concepts.
    proc bothTask3() {.needs: (FsReadCap, NetworkCap).} = discard
    let supAB = supervisor:
      provides(FsReadCap, NetworkCap)
      child bothTask3
    let supBA = supervisor:
      provides(NetworkCap, FsReadCap)
      child bothTask3
    static:
      doAssert typeof(supAB) is (GrantsFsReadCap and GrantsNetworkCap)
      doAssert typeof(supBA) is (GrantsFsReadCap and GrantsNetworkCap)
    check supAB != nil
    check supBA != nil

  test "provides split across two lines is order-independent":
    proc bothTask4() {.needs: (FsReadCap, NetworkCap).} = discard
    let supSplitAB = supervisor:
      provides(FsReadCap)
      provides(NetworkCap)
      child bothTask4
    let supSplitBA = supervisor:
      provides(NetworkCap)
      provides(FsReadCap)
      child bothTask4
    static:
      doAssert typeof(supSplitAB) is (GrantsFsReadCap and GrantsNetworkCap)
      doAssert typeof(supSplitBA) is (GrantsFsReadCap and GrantsNetworkCap)
    check supSplitAB != nil
    check supSplitBA != nil

suite "capconcept: user-defined caps via `cap T` (unbounded)":

  test "user-declared cap composes identically to built-ins":
    proc usesMyApp() {.needs: MyAppCap.} = discard
    let sup = supervisor:
      provides(MyAppCap)
      child usesMyApp
    static:
      doAssert typeof(sup) is GrantsMyAppCap
    check sup != nil

  test "user cap + built-in cap mix freely":
    proc usesBoth() {.needs: (FsReadCap, MyOtherCap).} = discard
    let sup = supervisor:
      provides(FsReadCap, MyOtherCap)
      child usesBoth
    static:
      doAssert typeof(sup) is (GrantsFsReadCap and GrantsMyOtherCap)
    check sup != nil

  test "missing user cap → compile error":
    proc needsMyThird() {.needs: MyThirdCap.} = discard
    check not compiles(
      block:
        let sup = supervisor:
          provides(FsReadCap)            # MyThirdCap missing
          child needsMyThird
        sup)

suite "capconcept: cross-module user-cap discharge":

  test "user cap declared in module A + task in A discharges in B's supervisor":
    let sup = supervisor:
      provides(CrossModCap)
      child crossModTask
    static:
      doAssert typeof(sup) is GrantsCrossModCap
    check sup != nil

  test "missing cross-module user cap → compile error":
    check not compiles(
      block:
        let sup = supervisor:
          provides(FsReadCap)            # CrossModCap not provided
          child crossModTask
        sup)

suite "capconcept: library-helper pattern (the μb motivation)":

  test "helper constrained by Grants concept accepts any supervisor providing the cap":
    let sup = supervisor:
      provides(CrossModCap)
    helperCalls = 0
    let n = helperNeedingCrossMod(sup)
    check n == 1
    check helperCalls == 1

  test "supervisor missing the helper's required cap → compile error at the call site":
    let sup = supervisor:
      provides(FsReadCap)               # CrossModCap not granted
    check not compiles(helperNeedingCrossMod(sup))

  test "helper accepts a supervisor with MORE caps than required":
    let sup = supervisor:
      provides(CrossModCap, FsReadCap, NetworkCap)
    helperCalls = 0
    discard helperNeedingCrossMod(sup)
    check helperCalls == 1

suite "capconcept: nested supervisors inherit parent caps":

  test "outer-only provides covers deeply nested child":
    proc deepTask() {.needs: FsReadCap.} = discard
    let sup = supervisor:
      provides(FsReadCap)
      supervisor:
        provides(NetworkCap)
        supervisor:
          provides(ProcessCap)
          child deepTask                # only needs FsReadCap, from outermost
    static:
      doAssert typeof(sup) is
        (GrantsFsReadCap and GrantsNetworkCap and GrantsProcessCap)
    check sup != nil

  test "deeply nested child whose need lives at a middle level discharges":
    proc midTask() {.needs: NetworkCap.} = discard
    let sup = supervisor:
      provides(FsReadCap)
      supervisor:
        provides(NetworkCap)
        supervisor:
          child midTask                 # needs NetworkCap, from one-up
    check sup != nil

  test "nested child whose need is in NO scope → compile error":
    proc orphan() {.needs: TerminalCap.} = discard
    check not compiles(
      block:
        let sup = supervisor:
          provides(FsReadCap)
          supervisor:
            provides(NetworkCap)        # TerminalCap missing everywhere
            child orphan
        sup)
