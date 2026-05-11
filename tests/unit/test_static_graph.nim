{.experimental: "callOperator".}

import std/[unittest, strformat]
import fresco/reactive/scope
import fresco/reactive/signal
import fresco/reactive/static_graph

suite "tracked: static dependency tracking":

  test "runs once on declaration":
    let count = signal(0)
    var runs = 0
    discard createRoot:
      tracked:
        discard count()
        inc runs
    check runs == 1

  test "re-runs when a statically-detected signal changes":
    let count = signal(0)
    var observed: seq[int] = @[]
    discard createRoot:
      tracked:
        observed.add count()
    count.set(1); count.set(2); count.set(3)
    check observed == @[0, 1, 2, 3]

  test "tracks multiple signals in one block":
    let a = signal(1)
    let b = signal(2)
    var seenVals: seq[int] = @[]
    discard createRoot:
      tracked:
        seenVals.add a() + b()
    a.set(10)
    b.set(20)
    check seenVals == @[3, 12, 30]

  test "tracks signal reads via .get() method form":
    let count = signal(0)
    var observed: seq[int] = @[]
    discard createRoot:
      tracked:
        observed.add count.get()
    count.set(5)
    check observed == @[0, 5]

  test "tracks reads inside conditional branches (superset)":
    let cond = signal(true)
    let a = signal("A")
    let b = signal("B")
    var observed: seq[string] = @[]
    discard createRoot:
      tracked:
        if cond():
          observed.add a()
        else:
          observed.add b()
    # cond=true: read a, observed=[A]
    a.set("AA")
    # over-fires on b too, but a() yields "AA"
    cond.set(false)
    b.set("BB")
    # All branches are subscribed; observer fires on every change.
    check "A" in observed
    check "AA" in observed
    check observed[^1] == "BB"

  test "tracks reads inside interpolations":
    let count = signal(0)
    var emitted: seq[string] = @[]
    discard createRoot:
      tracked:
        emitted.add fmt"count: {count()}"
    count.set(5)
    check emitted == @["count: 0", "count: 5"]

  test "scope dispose unsubscribes":
    let count = signal(0)
    var runs = 0
    let root = createRoot:
      tracked:
        discard count()
        inc runs
    check runs == 1
    count.set(1)
    check runs == 2
    dispose(root)
    count.set(2)
    check runs == 2     # no further runs after dispose

  test "untracked signals don't trigger":
    let tracked_sig = signal(0)
    let other = signal(0)
    var runs = 0
    discard createRoot:
      tracked:
        discard tracked_sig()
        inc runs
    other.set(99)     # not statically detected as a dep
    check runs == 1
    tracked_sig.set(1)
    check runs == 2
