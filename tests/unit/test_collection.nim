{.experimental: "callOperator".}

import std/unittest
import fresco/reactive/scope
import fresco/reactive/signal
import fresco/reactive/collection
import fresco/reactive/speculative
import fresco/journal/events
import fresco/journal/log

suite "CollectionSignal":

  test "empty initial state":
    let c = collection[int]()
    check c.len == 0
    check c.get() == newSeq[int]()

  test "push appends and emits dkInsert":
    let c = collection[string]()
    var deltas: seq[Delta[string]] = @[]
    discard createRoot:
      onDelta(c, proc(d: Delta[string]) = deltas.add d)
    c.push("a")
    c.push("b")
    c.push("c")
    check c.get() == @["a", "b", "c"]
    check deltas.len == 3
    for i, d in deltas:
      check d.kind == dkInsert
      check d.insertIdx == i

  test "pop removes last and emits dkRemove":
    let c = collection(@["a", "b", "c"])
    var deltas: seq[Delta[string]] = @[]
    discard createRoot:
      onDelta(c, proc(d: Delta[string]) = deltas.add d)
    let v = c.pop()
    check v == "c"
    check c.get() == @["a", "b"]
    check deltas.len == 1
    check deltas[0].kind == dkRemove
    check deltas[0].removeIdx == 2

  test "insert at index shifts later items":
    let c = collection(@["a", "c"])
    c.insert(1, "b")
    check c.get() == @["a", "b", "c"]

  test "remove at index":
    let c = collection(@["a", "b", "c"])
    c.remove(1)
    check c.get() == @["a", "c"]

  test "setAt updates one item and emits dkUpdate":
    let c = collection(@[1, 2, 3])
    var deltas: seq[Delta[int]] = @[]
    discard createRoot:
      onDelta(c, proc(d: Delta[int]) = deltas.add d)
    c.setAt(1, 99)
    check c.get() == @[1, 99, 3]
    check deltas[0].kind == dkUpdate
    check deltas[0].updateIdx == 1
    check deltas[0].updateVal == 99

  test "clear empties and emits dkClear":
    let c = collection(@[1, 2, 3])
    var deltas: seq[Delta[int]] = @[]
    discard createRoot:
      onDelta(c, proc(d: Delta[int]) = deltas.add d)
    c.clear()
    check c.len == 0
    check deltas[0].kind == dkClear

  test "set replaces wholesale and emits dkReplace":
    let c = collection(@[1, 2, 3])
    var deltas: seq[Delta[int]] = @[]
    discard createRoot:
      onDelta(c, proc(d: Delta[int]) = deltas.add d)
    c.set(@[10, 20])
    check c.get() == @[10, 20]
    check deltas[0].kind == dkReplace
    check deltas[0].replaceVal == @[10, 20]

  test "onDelta handlers unregister on scope dispose":
    let c = collection[int]()
    var deltas: seq[Delta[int]] = @[]
    let root = createRoot:
      onDelta(c, proc(d: Delta[int]) = deltas.add d)
    c.push(1)
    check deltas.len == 1
    dispose(root)
    c.push(2)
    check deltas.len == 1   # handler unregistered

  test "multiple handlers all receive deltas":
    let c = collection[int]()
    var sumA = 0
    var sumB = 0
    discard createRoot:
      onDelta(c, proc(d: Delta[int]) =
        if d.kind == dkInsert: sumA += d.insertVal)
      onDelta(c, proc(d: Delta[int]) =
        if d.kind == dkInsert: sumB += d.insertVal)
    c.push(3)
    c.push(7)
    check sumA == 10
    check sumB == 10

  test "plain reactive observers re-fire on collection changes":
    # Regression: CollectionSignal previously wasn't Subscribable and
    # never called notify(), so `createEffect` / `bindRows` reading
    # the items never re-ran on push/pop/etc.
    let c = collection(@["a"])
    var runs = 0
    var lastLen = 0
    discard createRoot:
      createEffect proc() =
        lastLen = c.len
        inc runs
    check runs == 1
    check lastLen == 1
    c.push("b")
    check runs == 2
    check lastLen == 2
    c.push("c")
    check runs == 3
    check lastLen == 3
    c.pop()
    check runs == 4
    check lastLen == 2

  test "plain observers fire on every delta kind":
    let c = collection(@[1, 2, 3])
    var runs = 0
    discard createRoot:
      createEffect proc() =
        discard c.get()
        inc runs
    let baseline = runs
    c.push(4);     check runs == baseline + 1
    c.insert(0, 0); check runs == baseline + 2
    c.setAt(1, 99); check runs == baseline + 3
    c.remove(0);    check runs == baseline + 4
    c.set(@[1, 2]); check runs == baseline + 5
    c.clear();      check runs == baseline + 6

suite "CollectionSignal: speculative scope":

  test "mutations roll back when block falls off without commit":
    # Regression for round-7 H5: previously CollectionSignal mutations
    # inside `speculative:` would silently stick on rollback, violating
    # DESIGN.md R11. Now they snapshot prior state and record a revert.
    let c = collection(@[1, 2, 3])
    discard speculative:
      c.push(4)
      c.push(5)
      check c.len == 5      # mutations visible inside block
    check c.get() == @[1, 2, 3]   # rolled back on block exit

  test "mutations stick when commit is called":
    let c = collection(@[1, 2, 3])
    discard speculative:
      c.push(4)
      c.setAt(0, 99)
      commit()
    check c.get() == @[99, 2, 3, 4]

  test "clear rolls back via dkReplace snapshot":
    let c = collection(@["a", "b", "c"])
    discard speculative:
      c.clear()
      check c.len == 0
    check c.get() == @["a", "b", "c"]

  test "set (wholesale replace) rolls back":
    let c = collection(@[1, 2, 3])
    discard speculative:
      c.set(@[10, 20, 30])
      check c.get() == @[10, 20, 30]
    check c.get() == @[1, 2, 3]

suite "CollectionSignal: edge cases":

  test "clear() on empty is a silent no-op (no delta, no observer fire)":
    let c = collection[int]()
    var observerRuns = 0
    discard createRoot:
      createEffect proc() =
        discard c.len
        inc observerRuns
    let baseline = observerRuns
    c.clear()    # already empty
    check observerRuns == baseline   # no fire

  test "pop on empty asserts":
    let c = collection[int]()
    expect AssertionDefect:
      discard c.pop()

  test "insert at out-of-bounds asserts":
    let c = collection(@[1, 2, 3])
    expect AssertionDefect:
      c.insert(99, 4)    # idx > len

  test "remove on out-of-bounds asserts":
    let c = collection(@[1, 2])
    expect AssertionDefect:
      c.remove(5)

  test "setAt on out-of-bounds asserts":
    let c = collection(@[1])
    expect AssertionDefect:
      c.setAt(2, 99)

suite "CollectionSignal: journal integration":

  setup:
    resetJournal()
    discard useJournal()

  teardown:
    resetJournal()

  test "labeled push emits ekCollectionDelta with insert op":
    let c = collection[int](@[], label = "items")
    c.push(42)
    let evs = globalJournal.byKind(ekCollectionDelta)
    check evs.len == 1
    check evs[0].collectionLabel == "items"
    check evs[0].collectionOp == "insert"
    check evs[0].collectionIdx == 0
    check evs[0].collectionRepr == "42"

  test "remove / update / clear / replace each emit the right op":
    let c = collection(@[1, 2, 3], label = "nums")
    c.remove(0)
    c.setAt(0, 99)
    c.clear()
    c.set(@[7, 8])
    let evs = globalJournal.byKind(ekCollectionDelta)
    check evs.len == 4
    check evs[0].collectionOp == "remove"
    check evs[0].collectionIdx == 0
    check evs[1].collectionOp == "update"
    check evs[2].collectionOp == "clear"
    check evs[2].collectionIdx == -1
    check evs[3].collectionOp == "replace"
    check evs[3].collectionRepr == "2"     # replace records the new length

  test "unlabeled collections skip journaling":
    let c = collection[int]()   # no label
    c.push(1)
    c.push(2)
    check globalJournal.byKind(ekCollectionDelta).len == 0
