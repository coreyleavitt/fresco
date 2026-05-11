{.experimental: "callOperator".}

import std/unittest
import fresco/reactive/scope
import fresco/reactive/signal
import fresco/reactive/speculative

suite "speculative":

  test "auto-rollback when block exits without commit":
    let count = signal(0)
    let title = signal("init")
    discard speculative:
      count := 5
      title := "mid"
    check count() == 0
    check title() == "init"

  test "commit makes writes stick":
    let count = signal(0)
    discard speculative:
      count := 7
      commit()
    check count() == 7

  test "exception inside auto-rolls back and re-raises":
    let count = signal(0)
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
    let count = signal(3)
    var seenInside = 0
    discard speculative:
      count := 10
      seenInside = count()
    check seenInside == 10
    check count() == 3       # rolled back after exit

  test "multiple writes to same signal: rollback restores first prior":
    let count = signal(1)
    discard speculative:
      count := 2
      count := 3
      count := 4
    check count() == 1       # all the way back to 1

  test "nested: inner commit, outer rollback → outer reverts inner's commit":
    let x = signal(0)
    discard speculative:
      x := 5
      discard speculative:
        x := 9
        commit()
      # x is 9 here; outer hasn't committed
      check x() == 9
    check x() == 0           # outer's revert reaches all the way

  test "nested: inner rollback alone":
    let x = signal(0)
    discard speculative:
      x := 5
      discard speculative:
        x := 9
        # no commit → inner rolls back to 5
      check x() == 5
      commit()
    check x() == 5

  test "rolled-back writes re-notify observers":
    let count = signal(0)
    var seenVals: seq[int] = @[]
    discard createRoot:
      createEffect proc() = seenVals.add count()
    seenVals.setLen(0)
    discard speculative:
      count := 5
      count := 7
    # After rollback, observer should be informed of the final state.
    check seenVals[^1] == 0
