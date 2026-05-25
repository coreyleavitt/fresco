{.experimental: "callOperator".}

import std/[unittest, strutils]
import intonaco/reactive/scope
import intonaco/reactive/signal
import intonaco/reactive/runtime
import intonaco/reactive/collection
import intonaco/reactive/speculative
import intonaco/journal/events
import intonaco/journal/log

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

  test "#68-family: N>=3 delta handlers all fire on push":
    # Sibling of #68's Signal-observer fix at the deltaObservers
    # site. `fanout` uses the same snapshot-then-iterate-while-
    # callbacks-may-mutate pattern that needed fixing for
    # Signal.observers — N=3 ensures we exercise the same regime.
    let c = collection[int]()
    var seenA, seenB, seenC = 0
    discard createRoot:
      onDelta(c, proc(d: Delta[int]) =
        if d.kind == dkInsert: seenA = d.insertVal)
      onDelta(c, proc(d: Delta[int]) =
        if d.kind == dkInsert: seenB = d.insertVal)
      onDelta(c, proc(d: Delta[int]) =
        if d.kind == dkInsert: seenC = d.insertVal)
    c.push(42)
    check seenA == 42
    check seenB == 42
    check seenC == 42

  test "#68-family: delta handler that disposes a sibling scope doesn't break iteration":
    # A handler disposes a sibling scope. The sibling's onCleanup
    # runs immediately, calling `captured.deltaObservers.del idx`
    # — this mutates the live deltaObservers list while `fanout`
    # is iterating. The remaining handlers must still fire.
    let c = collection[int]()
    var aFired, cFired = 0
    var bScope: Scope
    let root = createRoot:
      onDelta(c, proc(d: Delta[int]) =
        inc aFired
        dispose(bScope))             # ← removes B's handler mid-fanout
      bScope = newScope(parent = currentScope)
      withScope(bScope):
        onDelta(c, proc(d: Delta[int]) =
          discard d)                  # B's body; B itself fires this cycle
      onDelta(c, proc(d: Delta[int]) =
        inc cFired)
    c.push(1)
    check aFired == 1
    check cFired == 1                 # C must still fire after B was disposed
    dispose(root)

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

  test "clear inside speculative is reversed by a dkReplace inverse":
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

  test "M mutations + rollback fire ONE batched dkRollback with M inverses":
    let c = collection(@[10, 20, 30])
    var deltas: seq[Delta[int]] = @[]
    discard createRoot:
      onDelta(c, proc(d: Delta[int]) = deltas.add d)
    let baseline = deltas.len    # zero, but defensive
    discard speculative:
      c.push(40)        # forward dkInsert
      c.setAt(0, 99)    # forward dkUpdate
      c.pop()           # forward dkRemove
    # Forward deltas fired during the block; one dkRollback fires on exit.
    let total = deltas.len - baseline
    check total == 4    # 3 forward + 1 batched rollback
    check deltas[^1].kind == dkRollback
    check deltas[^1].rollbackOps.len == 3
    # Inverses recorded chronologically: pop's inverse last, in the seq
    check deltas[^1].rollbackOps[0].kind == dkRemove   # inverse-of-push
    check deltas[^1].rollbackOps[1].kind == dkUpdate   # inverse-of-setAt (restores 10)
    check deltas[^1].rollbackOps[1].updateVal == 10
    check deltas[^1].rollbackOps[2].kind == dkInsert   # inverse-of-pop
    check c.get() == @[10, 20, 30]

  test "pop inside speculative + rollback restores the popped value":
    let c = collection(@["a", "b", "c"])
    discard speculative:
      let v = c.pop()
      check v == "c"
      check c.get() == @["a", "b"]
    check c.get() == @["a", "b", "c"]

  test "setAt rollback restores prior value via dkUpdate inverse, not dkReplace":
    let c = collection(@[1, 2, 3])
    var deltas: seq[Delta[int]] = @[]
    discard createRoot:
      onDelta(c, proc(d: Delta[int]) = deltas.add d)
    discard speculative:
      c.setAt(1, 99)
    # Two deltas total: forward dkUpdate, batched dkRollback containing one dkUpdate
    check deltas[^1].kind == dkRollback
    check deltas[^1].rollbackOps.len == 1
    check deltas[^1].rollbackOps[0].kind == dkUpdate
    check deltas[^1].rollbackOps[0].updateVal == 2
    check c.get() == @[1, 2, 3]

  test "nested: inner commit promotes inverses, outer rollback drains both":
    let c = collection(@[0])
    var batches: seq[Delta[int]] = @[]
    discard createRoot:
      onDelta(c, proc(d: Delta[int]) =
        if d.kind == dkRollback: batches.add d)
    discard speculative:
      c.push(1)             # outer
      discard speculative:
        c.push(2)           # inner
        c.push(3)           # inner
        commit()
      c.push(4)             # outer (after inner committed)
    # Inner commit fired NO rollback batch.
    # Outer rollback fired ONE batch with all 4 mutations' inverses.
    check batches.len == 1
    check batches[0].rollbackOps.len == 4
    check c.get() == @[0]

  test "nested: inner rollback fires its own batch; outer mutations intact":
    let c = collection(@[0])
    var batches: seq[Delta[int]] = @[]
    discard createRoot:
      onDelta(c, proc(d: Delta[int]) =
        if d.kind == dkRollback: batches.add d)
    discard speculative:
      c.push(1)             # outer — sticks (commit on outer)
      discard speculative:
        c.push(2)           # inner — gets rolled back
        c.push(3)           # inner — gets rolled back
      # inner rolled back here; outer continues
      c.push(4)             # outer — sticks
      commit()
    # One rollback batch from inner; nothing on outer (it committed).
    check batches.len == 1
    check batches[0].rollbackOps.len == 2
    check c.get() == @[0, 1, 4]

  test "multiple collections in same scope each emit their own dkRollback":
    let a = collection[int]()
    let b = collection[int]()
    var aBatches, bBatches: seq[Delta[int]] = @[]
    discard createRoot:
      onDelta(a, proc(d: Delta[int]) =
        if d.kind == dkRollback: aBatches.add d)
      onDelta(b, proc(d: Delta[int]) =
        if d.kind == dkRollback: bBatches.add d)
    discard speculative:
      a.push(1); a.push(2)
      b.push(10); b.push(20); b.push(30)
    check aBatches.len == 1
    check aBatches[0].rollbackOps.len == 2
    check bBatches.len == 1
    check bBatches[0].rollbackOps.len == 3
    check a.get().len == 0
    check b.get().len == 0

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

  test "delta handler that mutates during rollback fanout doesn't corrupt state":
    # Reentrancy guard: when a rollback hook fires the dkRollback delta
    # to handlers, a handler may legitimately call `push`/`setAt`/etc
    # on the same collection (e.g., to record the rollback in a sibling
    # collection, or trigger a state-machine transition). Those calls
    # re-enter `captureInverse`. The protection is in speculative.nim:
    # `scope.committed` is set BEFORE onRollbackHooks fire, so
    # `captureInverse`'s `not committed` gate short-circuits and no
    # orphan rollback entry is pushed onto `c.rollbackHead`.
    #
    # Without this protection, the head pop at the end of the rollback
    # hook would pop the *new* (mid-hook) entry, leaving the original
    # entry stuck on the head — a memory leak and a state-machine bug
    # waiting for the next scope's rollback.
    let c = collection[int]()
    var sawReentrantInsert = false
    var firedOnce = false
    onDelta(c, proc(d: Delta[int]) =
      if d.kind == dkRollback and not firedOnce:
        # Mid-rollback: mutate the same collection. Must not crash,
        # must not leave c.rollbackHead non-nil. Fire only on the
        # FIRST rollback the handler sees, otherwise subsequent
        # cycles would keep re-injecting 999.
        firedOnce = true
        c.push(999)
      elif d.kind == dkInsert and d.insertVal == 999:
        sawReentrantInsert = true)
    discard speculative:
      c.push(1)
      c.push(2)
    check sawReentrantInsert            # handler's reentrant push fired
    check c.get() == @[999]             # rolled-back to [], then push(999)
    # Second rollback cycle: if the first had left an orphan entry on
    # c.rollbackHead, captureInverse's "head.scope != currentSpeculative"
    # check would still see the stale entry and the inverses for
    # this scope's writes would attach to it — the rollback would
    # either no-op or pop the wrong batch.
    discard speculative:
      c.push(50)
      c.push(60)
    check c.get() == @[999]             # both pushes rolled back cleanly

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

  test "rollback writes exactly ONE ekCollectionRollback per affected collection":
    let c = collection[int](@[], label = "items")
    discard speculative:
      c.push(1)
      c.push(2)
      c.push(3)
    let forwards = globalJournal.byKind(ekCollectionDelta)
    let rollbacks = globalJournal.byKind(ekCollectionRollback)
    check forwards.len == 3     # forward mutations still journal
    check rollbacks.len == 1    # one boundary event
    check rollbacks[0].rollbackLabel == "items"
    check rollbacks[0].rollbackCount == 3
    # opsRepr: ";".join three "r:idx" tokens
    check rollbacks[0].rollbackOpsRepr.contains("r:")

  test "two labeled collections in one rollback → two rollback events":
    let a = collection[int](@[], label = "a")
    let b = collection[int](@[], label = "b")
    discard speculative:
      a.push(1)
      b.push(2)
      b.push(3)
    let rbs = globalJournal.byKind(ekCollectionRollback)
    check rbs.len == 2
    let byLabel = block:
      var t: tuple[a, b: int]
      for ev in rbs:
        if ev.rollbackLabel == "a": t.a = ev.rollbackCount
        elif ev.rollbackLabel == "b": t.b = ev.rollbackCount
      t
    check byLabel.a == 1
    check byLabel.b == 2

  test "unlabeled collection rollback skips journal":
    let c = collection[int]()   # no label
    discard speculative:
      c.push(1)
      c.push(2)
    check globalJournal.byKind(ekCollectionRollback).len == 0

  test "commit does NOT write a rollback event":
    let c = collection[int](@[], label = "x")
    discard speculative:
      c.push(1)
      commit()
    check globalJournal.byKind(ekCollectionRollback).len == 0
