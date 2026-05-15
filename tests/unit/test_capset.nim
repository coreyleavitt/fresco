## Compile-time capability set primitives (#35 C1).
##
## Foundation tests: type identity by static[CapSet] value, plus the
## set primitives (contains/union/isSubsetOf/missing).

import std/unittest
import fresco/reactive/capset

type Phantom[Caps: static[CapSet]] = ref object

suite "capset: type-identity by static[uint64] value":

  test "same value, different expression → same type":
    type P1 = Phantom[capBit(ckFsRead) or capBit(ckNetwork)]
    type P2 = Phantom[capBit(ckNetwork) or capBit(ckFsRead)]
    check (P1 is P2)
    check (P2 is P1)

  test "different values → different types":
    type P1 = Phantom[capBit(ckFsRead) or capBit(ckNetwork)]
    type P2 = Phantom[capBit(ckFsRead) or capBit(ckProcess)]
    check not (P1 is P2)

  test "via const intermediates preserves identity":
    const a = capBit(ckFsRead) or capBit(ckNetwork)
    const b = capBit(ckNetwork) or capBit(ckFsRead)
    check a == b
    type P1 = Phantom[a]
    type P2 = Phantom[b]
    check (P1 is P2)

  test "empty cap set has its own identity":
    type Pe = Phantom[EmptyCaps]
    type P1 = Phantom[capBit(ckFsRead)]
    check not (Pe is P1)
    type Pe2 = Phantom[0'u64]
    check (Pe is Pe2)

suite "capset: set operations":

  test "contains: bit membership":
    const s = capBit(ckFsRead) or capBit(ckNetwork)
    check s.contains(ckFsRead)
    check s.contains(ckNetwork)
    check not s.contains(ckProcess)

  test "union: set OR":
    const a = capBit(ckFsRead)
    const b = capBit(ckNetwork)
    check union(a, b) == (capBit(ckFsRead) or capBit(ckNetwork))
    check union(a, a) == a   # idempotent

  test "isSubsetOf: subset check":
    const big = capBit(ckFsRead) or capBit(ckNetwork) or capBit(ckProcess)
    const small = capBit(ckFsRead) or capBit(ckNetwork)
    check small.isSubsetOf(big)
    check big.isSubsetOf(big)    # reflexive
    check not big.isSubsetOf(small)

  test "missing: bits in required but not in provided":
    const required = capBit(ckFsRead) or capBit(ckNetwork) or capBit(ckProcess)
    const provided = capBit(ckFsRead)
    check missing(required, provided) ==
          (capBit(ckNetwork) or capBit(ckProcess))
    check missing(required, required) == 0'u64
