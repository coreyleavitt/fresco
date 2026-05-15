## User-defined capability registration (#54).

import std/[macros, unittest]
import fresco/reactive/capset
import fresco/reactive/capabilities

# Each registerCap call below claims the next free ckUser slot.
# These run at module-init time (CT counter advances in declaration
# order), so MyCapA → ckUser0, MyCapB → ckUser1, etc. — the tests
# below verify that mapping.
type
  MyCapA = ref object
  MyCapB = ref object

registerCap MyCapA
registerCap MyCapB

suite "registerCap: slot allocation":

  test "first registerCap claims ckUser0":
    check capKindFor(MyCapA) == ckUser0

  test "second registerCap claims ckUser1 (monotonic)":
    check capKindFor(MyCapB) == ckUser1

proc usesA() {.needs: MyCapA.} = discard
proc usesAB() {.needs: (MyCapA, MyCapB).} = discard

suite "registerCap: integration with {.needs.} and staticSupervisor":

  test "{.needs: MyCap.} works after registration":
    let sup = staticSupervisor:
      provides(MyCapA)
      child usesA
    check sup != nil

  test "user caps + built-in caps mix freely":
    proc usesMixed() {.needs: (FsReadCap, MyCapA).} = discard
    let sup = staticSupervisor:
      provides(FsReadCap, MyCapA)
      child usesMixed
    check sup != nil

  test "missing user cap → compile error":
    check not compiles(
      block:
        let sup = staticSupervisor:
          provides(MyCapA)
          child usesAB    # needs MyCapB too
        sup)

suite "registerCap: error paths":

  test "duplicate registerCap on the same type → compile error":
    # Re-registering MyCapA (already registered at module top) is a
    # silent footgun: would waste a slot AND produce two conflicting
    # `capKindFor` overloads. Detect at compile time.
    check not compiles(registerCap MyCapA)

  test "59th registerCap (slot exhaustion) → compile error":
    # The bitmap ceiling: 6 built-in caps + 58 user slots = 64 bits.
    # Past slot 57, registerCap must error rather than silently
    # truncate or wrap.
    macro genTooMany(): untyped =
      result = newStmtList()
      for i in 0 ..< 59:
        let tname = ident("Overflow" & $i)
        result.add quote do:
          type `tname` = ref object
          registerCap `tname`
    check not compiles(genTooMany())
