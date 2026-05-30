{.experimental: "callOperator".}

import std/unittest
include intonaco/reactive_internal

suite "speculative":

  test "auto-rollback when block exits without commit":
    let count {.height: 0.} = signalC(0)
    let title {.height: 0.} = signalC("init")
    discard speculative:
      count := 5
      title := "mid"
    check count() == 0
    check title() == "init"

  test "commit makes writes stick":
    let count {.height: 0.} = signalC(0)
    discard speculative:
      count := 7
      commit()
    check count() == 7

  test "exception inside auto-rolls back and re-raises":
    let count {.height: 0.} = signalC(0)
    var caught = false
    try:
      discard speculative:
        count := 99
        raise newException(ValueError, "abort")
    except ValueError:
      caught = true
    check caught
    check count() == 0

  test "reads inside the block see speculative values":
    let count {.height: 0.} = signalC(3)
    var seenInside = 0
    discard speculative:
      count := 10
      seenInside = count()
    check seenInside == 10
    check count() == 3       # rolled back after exit

  test "multiple writes to same signal: rollback restores first prior":
    let count {.height: 0.} = signalC(1)
    discard speculative:
      count := 2
      count := 3
      count := 4
    check count() == 1       # all the way back to 1

  test "nested: inner commit, outer rollback → outer reverts inner's commit":
    let x {.height: 0.} = signalC(0)
    discard speculative:
      x := 5
      discard speculative:
        x := 9
        commit()
      # x is 9 here; outer hasn't committed
      check x() == 9
    check x() == 0           # outer's revert reaches all the way

  test "nested: inner rollback alone":
    let x {.height: 0.} = signalC(0)
    discard speculative:
      x := 5
      discard speculative:
        x := 9
        # no commit → inner rolls back to 5
      check x() == 5
      commit()
    check x() == 5

  test "rolled-back writes re-notify observers":
    let count {.height: 0.} = signalC(0)
    var seenVals: seq[int] = @[]
    discard createRoot:
      createEffect proc() = seenVals.add count()
    seenVals.setLen(0)
    discard speculative:
      count := 5
      count := 7
    # After rollback, observer should be informed of the final state.
    check seenVals[^1] == 0

  test "observer-triggered writes during rollback are themselves rolled back":
    # Regression for review #11: rollback fires reverts → notify
    # observers → effects may signal.set. Previously the new reverts
    # pushed during rollback iteration were dropped (setLen(0) after
    # the for-loop). Now rollback drains until reverts is empty.
    let a {.height: 0.} = signalC(0)
    let b {.height: 0.} = signalC(0)
    discard createRoot:
      createEffect proc() =
        # When `a` changes, this effect mirrors it into `b`.
        b.set(a())
    discard speculative:
      a := 5      # → effect fires, b := 5 inside the same frame
    # After rollback both a and b must return to 0.
    check a() == 0
    check b() == 0

  test "currentSpeculative restored even when a revert closure raises Defect":
    # Regression for round-4 H3: previously a Defect propagating out of
    # `rollback` (e.g. from a buggy revert closure) bypassed the
    # `currentSpeculative = prevSpec` restore. Now rollback runs inside
    # an inner finally; the outer finally unconditionally restores.
    let touched {.height: 0.} = signalC(0)
    var caught = false
    try:
      discard speculative:
        touched := 1
        # Synthesize a revert closure that raises a Defect when fired.
        # `onSpeculativeRevert` is the per-write extension hook (used
        # internally by signal.set); push a closure we know will raise.
        onSpeculativeRevert proc() = raise newException(Defect, "boom-in-revert")
    except Defect:
      caught = true
    check caught
    check currentSpeculative == nil   # restored even with Defect

  test "currentSpeculative restored even when body raises a Defect":
    # Regression for round-3 H8: previously the threadvar restore
    # lived after the try/except CatchableError, so a Defect would
    # bypass it and leak `currentSpeculative` pointing at a dead
    # frame. After the fix the restore is in a `finally`.
    let x {.height: 0.} = signalC(0)
    var caught = false
    try:
      discard speculative:
        x := 5
        raise newException(Defect, "synthetic")
    except Defect:
      caught = true
    check caught
    # Threadvar must be back to its pre-block value (nil at top level).
    check currentSpeculative == nil
    # A subsequent speculative block must work normally.
    discard speculative:
      x := 10
    check x() == 0  # rolled back cleanly

  test "nested: outer rollback undoes inner commit even with no outer writes":
    # Regression for review #12: previously inner commit cleared its
    # own reverts without promoting them. If the outer made no writes
    # of its own, outer.reverts was empty, so outer rollback was a
    # no-op and the inner-committed writes survived. Now an inner
    # commit promotes its reverts to the parent frame.
    let x {.height: 0.} = signalC(0)
    discard speculative:
      discard speculative:
        x := 7
        commit()
      # x is 7 here; outer hasn't committed and has no writes of its own
      check x() == 7
    # Outer rolls back; the promoted revert restores x.
    check x() == 0
