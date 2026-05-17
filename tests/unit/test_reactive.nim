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

  test "#68-family: dispose cascades through N>=3 children, every cleanup runs":
    # Sibling of the #68 family. scope.dispose does `let childSnap =
    # s.children; s.children.setLen(0); for i in countdown(...):
    # dispose(childSnap[i])` — a snapshot-then-clear-then-iterate
    # pattern. If cursor inference made childSnap an alias of
    # s.children, the `setLen(0)` would zero its length and the
    # for-loop would skip every child's dispose entirely.
    var rootRan = false
    var c0Ran, c1Ran, c2Ran = false
    let root = newScope()
    withScope(root):
      onCleanup proc() = rootRan = true
      let c0 = newScope(root)
      withScope(c0): onCleanup proc() = c0Ran = true
      let c1 = newScope(root)
      withScope(c1): onCleanup proc() = c1Ran = true
      let c2 = newScope(root)
      withScope(c2): onCleanup proc() = c2Ran = true
    dispose(root)
    check c0Ran
    check c1Ran
    check c2Ran
    check rootRan

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

suite "createEffect: shared-signal reentrancy":

  test "#68 regression: N>=3 observers on one signal all re-fire on write":
    # Reactive substrate must allow N observers on one signal; every
    # observer's body re-runs on every write. Under ORC cursor
    # inference, the snapshot-then-iterate-while-mutating pattern in
    # `notify` aliased the live observer list and silently dropped
    # the trailing observers — only the first two re-fired on N>=3.
    # Reproduces at N=3; would have stayed hidden at N=2 because
    # seq.del's swap-delete happens to round-trip correctly for two.
    var out1, out2, out3: string
    let sig = signal("a")
    discard createRoot:
      createEffect proc() = out1 = "1:" & sig()
      createEffect proc() = out2 = "2:" & sig()
      createEffect proc() = out3 = "3:" & sig()
    check out1 == "1:a" and out2 == "2:a" and out3 == "3:a"
    sig.set("b")
    check out1 == "1:b"
    check out2 == "2:b"
    check out3 == "3:b"           # ← the assertion that failed pre-fix
    sig.set("c")
    check out1 == "1:c" and out2 == "2:c" and out3 == "3:c"

  test "observer that adds a new observer fires next cycle, not this one":
    # Contract: structural mutations to the observer set during a
    # notify cycle are visible on subsequent cycles, never the
    # current one. Encoded in StableIterSeq.iterRO.
    var sig = signal(0)
    var initialRuns = 0
    var newObserverRuns = 0
    discard createRoot:
      createEffect proc() =
        discard sig()
        inc initialRuns
        if initialRuns == 2:
          # second run of the initial observer adds a new observer
          createEffect proc() =
            discard sig()
            inc newObserverRuns
    check initialRuns == 1
    sig.set(1)                    # triggers initial-observer rerun
    # The newly-created observer ran once on its own creation
    # (createEffect always invokes the body immediately), but it
    # should NOT have been included in the current notify cycle.
    check initialRuns == 2
    check newObserverRuns == 1    # only the initial-creation run

  test "observer that disposes itself during run doesn't break siblings":
    let sig = signal(0)
    var aRuns, bRuns, cRuns = 0
    var aScope: Scope
    let root = createRoot:
      aScope = newScope(parent = currentScope)
      withScope(aScope):
        createEffect proc() =
          discard sig()
          inc aRuns
          if aRuns >= 2: dispose(aScope)
      createEffect proc() =
        discard sig()
        inc bRuns
      createEffect proc() =
        discard sig()
        inc cRuns
    check aRuns == 1 and bRuns == 1 and cRuns == 1
    sig.set(1)                    # a disposes itself; b and c must still fire
    check aRuns == 2
    check bRuns == 2
    check cRuns == 2
    sig.set(2)                    # a is disposed; b and c continue
    check aRuns == 2              # frozen
    check bRuns == 3
    check cRuns == 3
    dispose(root)

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
