{.experimental: "callOperator".}

import std/unittest
import fresco/reactive/scope
import fresco/reactive/signal

suite "scope":

  test "newScope without parent has none":
    let s = newScope()
    check s.parent == nil
    check not s.disposed

  test "newScope with parent registers as child":
    let p = newScope()
    let c = newScope(p)
    check c.parent == p
    dispose(p)
    check c.disposed

  test "dispose runs cleanups in reverse registration order":
    var log: seq[int] = @[]
    let s = newScope()
    withScope(s):
      onCleanup proc() = log.add 1
      onCleanup proc() = log.add 2
      onCleanup proc() = log.add 3
    dispose(s)
    check log == @[3, 2, 1]

  test "dispose is idempotent":
    var calls = 0
    let s = newScope()
    withScope(s):
      onCleanup proc() = inc calls
    dispose(s)
    dispose(s)
    check calls == 1

  test "dispose cascades to children before parent cleanups":
    var log: seq[string] = @[]
    let p = newScope()
    withScope(p):
      onCleanup proc() = log.add "parent"
      let c = newScope(p)
      withScope(c):
        onCleanup proc() = log.add "child"
    dispose(p)
    check log == @["child", "parent"]

  test "createRoot returns a usable disposable scope":
    var ran = false
    let root = createRoot:
      onCleanup proc() = ran = true
    check not ran
    dispose(root)
    check ran

suite "signal":

  test "read and write the current value":
    let s = signal(0)
    check s.get() == 0
    s.set(5)
    check s.get() == 5

  test "call-syntax reads the value":
    let s = signal("hello")
    check s() == "hello"

  test "setting to the same value short-circuits (no re-runs)":
    let s = signal(7)
    var runs = 0
    discard createRoot:
      createEffect proc() =
        discard s()
        inc runs
    check runs == 1
    s.set(7)
    check runs == 1
    s.set(8)
    check runs == 2

suite "createEffect":

  test "runs once on registration; re-runs when a tracked signal changes":
    let s = signal(0)
    var observed: seq[int] = @[]
    discard createRoot:
      createEffect proc() =
        observed.add s()
    check observed == @[0]
    s.set(1); s.set(2); s.set(3)
    check observed == @[0, 1, 2, 3]

  test "does not re-run for untracked signal changes":
    let tracked = signal(0)
    let untracked = signal(0)
    var runs = 0
    discard createRoot:
      createEffect proc() =
        discard tracked()
        inc runs
    untracked.set(99)
    check runs == 1
    tracked.set(1)
    check runs == 2

  test "tracks multiple signals; any change re-runs":
    let a = signal(1)
    let b = signal(2)
    var sums: seq[int] = @[]
    discard createRoot:
      createEffect proc() =
        sums.add a() + b()
    a.set(10)
    b.set(20)
    check sums == @[3, 12, 30]

  test "scope dispose stops the effect":
    let s = signal(0)
    var runs = 0
    let root = createRoot:
      createEffect proc() =
        discard s()
        inc runs
    check runs == 1
    s.set(1)
    check runs == 2
    dispose(root)
    s.set(2)
    check runs == 2

  test "dynamic dependencies: a signal no longer read stops triggering":
    let cond = signal(true)
    let a = signal("a")
    let b = signal("b")
    var seenVals: seq[string] = @[]
    discard createRoot:
      createEffect proc() =
        if cond():
          seenVals.add a()
        else:
          seenVals.add b()
    check seenVals == @["a"]
    a.set("A")
    check seenVals == @["a", "A"]
    cond.set(false)
    check seenVals == @["a", "A", "b"]
    # Now `a` is no longer in the dependency set — its update is ignored.
    a.set("A!")
    check seenVals == @["a", "A", "b"]
    b.set("B")
    check seenVals == @["a", "A", "b", "B"]

suite "createComputed":

  test "derives from source signal and stays in sync":
    let count = signal(2)
    var doubled: Signal[int]
    discard createRoot:
      doubled = createComputed proc(): int = count() * 2
    check doubled.get() == 4
    count.set(10)
    check doubled.get() == 20

  test "computed itself is observable by other effects":
    let count = signal(1)
    var seenVals: seq[int] = @[]
    discard createRoot:
      let plus10 = createComputed proc(): int = count() + 10
      createEffect proc() = seenVals.add plus10()
    check seenVals == @[11]
    count.set(5)
    check seenVals == @[11, 15]

  test "computed disposes with its scope":
    let count = signal(0)
    var computed: Signal[int]
    let root = createRoot:
      computed = createComputed proc(): int = count() * 3
    check computed.get() == 0
    dispose(root)
    # After dispose the computed stops tracking; it holds its last value.
    count.set(7)
    check computed.get() == 0
