{.experimental: "callOperator".}

import std/unittest
import fresco/reactive/scope
import fresco/reactive/signal
import fresco/reactive/collection

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
