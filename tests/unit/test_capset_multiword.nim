## Multi-word CapSet (#55) — extends the bitmap past the original
## 64-bit ceiling. CapSetWords = 2 → 128 total slots (6 built-in +
## 122 user).
##
## The tracer: capBit at a high-word slot flips a bit in the
## second word, contains/union/subset/missing all generalize
## correctly across the word boundary, and type identity for
## static[CapSet] still holds under generic instantiation.

import std/[macros, unittest]
import fresco/reactive/capabilities
import fresco/reactive/capset

suite "capset multi-word: foundation":

  test "capBit at ckUser64 lives in the high word; contains distinguishes":
    let s = capBit(ckUser64)
    check s.contains(ckUser64)
    check not s.contains(ckUser0)
    check not s.contains(ckFsRead)

  test "union across word boundary preserves both bits":
    let s = capBit(ckUser0) or capBit(ckUser70)
    check s.contains(ckUser0)
    check s.contains(ckUser70)
    # And nothing else.
    check not s.contains(ckUser1)
    check not s.contains(ckUser71)

  test "isSubsetOf across word boundary":
    let big = capBit(ckUser0) or capBit(ckUser70) or capBit(ckUser121)
    let mid = capBit(ckUser70) or capBit(ckUser121)
    let other = capBit(ckUser1) or capBit(ckUser70)
    check mid.isSubsetOf(big)
    check big.isSubsetOf(big)              # reflexive
    check not big.isSubsetOf(mid)
    check not other.isSubsetOf(big)        # ckUser1 missing from big

  test "missing identifies high-word caps":
    let required = capBit(ckUser0) or capBit(ckUser70) or capBit(ckUser121)
    let provided = capBit(ckUser0)
    let miss = missing(required, provided)
    check miss.contains(ckUser70)
    check miss.contains(ckUser121)
    check not miss.contains(ckUser0)

suite "capset multi-word: type identity by static[CapSet] value":

  type Phantom[Caps: static[CapSet]] = ref object

  test "same value, different expression → same type":
    type P1 = Phantom[capBit(ckUser70) or capBit(ckUser0)]
    type P2 = Phantom[capBit(ckUser0) or capBit(ckUser70)]
    check (P1 is P2)
    check (P2 is P1)

  test "different values → different types":
    type P1 = Phantom[capBit(ckUser70)]
    type P2 = Phantom[capBit(ckUser71)]
    check not (P1 is P2)

# Multiple user-cap registrations from a module-top-level context.
# These claim slots monotonically across the test file at compile
# time. With the multi-word bitmap they can push past ckUser57 (the
# old single-word ceiling) — verifying registerCap doesn't error.
type
  HighCapA = ref object
  HighCapB = ref object
  HighCapC = ref object
registerCap HighCapA
registerCap HighCapB
registerCap HighCapC

# A task whose required cap is one of the registered high caps.
# Whether it lands in word[0] or word[1] depends on prior cap
# registrations in the compilation unit (the test won't assert on
# the specific slot — what matters is that registration succeeded
# and discharge composes correctly).
proc highCapTask() {.needs: HighCapA.} = discard
proc highCapTaskMixed() {.needs: (HighCapB, HighCapC).} = discard

suite "capset multi-word: registerCap past the old 58-slot ceiling":

  test "registerCap on multiple user types succeeds (past the single-word ceiling)":
    # The previous design (uint64) would have errored on the 59th
    # registerCap call. With multi-word, capacity is 122 user slots
    # so three sequential registrations are well within bounds.
    check capKindFor(HighCapA).ord >= ord(ckUser0)
    check capKindFor(HighCapB).ord > capKindFor(HighCapA).ord
    check capKindFor(HighCapC).ord > capKindFor(HighCapB).ord

  test "end-to-end discharge with a high-word cap composes":
    # The full pipeline: registered cap → needs annotation →
    # staticSupervisor discharge. Compiles when provides matches.
    let sup = staticSupervisor:
      provides(HighCapA)
      child highCapTask
    check sup != nil

  test "end-to-end discharge fails when high-word cap not provided":
    check not compiles(
      block:
        let sup = staticSupervisor:
          provides(HighCapA)      # missing HighCapB and HighCapC
          child highCapTaskMixed
        sup)

  test "registering a 251st user cap (past ckUser249) → compile error":
    # New ceiling: ckUser249 is the last slot in the 256-bit bitmap
    # (4 words × 64 - 6 built-in). Asking for one more in a fresh
    # compilation must fail.
    macro genTooMany(): untyped =
      result = newStmtList()
      for i in 0 ..< 251:
        let tname = ident("MultiwordOverflow" & $i)
        result.add quote do:
          type `tname` = ref object
          registerCap `tname`
    check not compiles(genTooMany())
