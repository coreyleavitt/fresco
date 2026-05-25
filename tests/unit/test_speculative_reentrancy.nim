## Speculative revert → notify → resubscribe reentrancy characterization (#51).
##
## The audit flagged `signal.setCore`'s revert closure as "probably safe
## but not characterized." This file pins the contract: cross-signal
## source/observer wiring stays consistent through speculative rollback,
## including conditional reads and write-during-rollback cascades.

import std/unittest
import intonaco/reactive/scope
import intonaco/reactive/signal
import intonaco/reactive/runtime
import intonaco/reactive/speculative
import intonaco/reactive/subscribable

suite "speculative reentrancy: source/observer wiring after rollback":

  test "effect reads A and B; rollback restores values + keeps both sources":
    let a = signal(0)
    let b = signal(20)
    var lastA, lastB: int
    var compRef: Computation
    discard createRoot:
      createEffect proc() =
        lastA = a()
        lastB = b()
      compRef = currentComputation  # snapshot the just-created effect's Computation
    # Note: currentComputation is nil outside an effect body — the
    # snapshot above happens at the inner-of-the-block instant when
    # createEffect's first run() is still on the stack. To capture
    # reliably, run the effect once more after a no-op write — except
    # we need a stable ref. Easier: createEffect returns nothing, so
    # we have to reach into the subscribable's observer list.
    # Both signals should have exactly one observer (the effect).
    check Subscribable(a).observers.len == 1
    check Subscribable(b).observers.len == 1
    let effect = Subscribable(a).observers[0]
    check Subscribable(b).observers[0] == effect

    discard speculative:
      a.set(1)         # revert: a=0
      b.set(99)        # revert: b=20
      a.set(2)         # revert: a=1
      # block exits without commit → rollback fires

    # Values restored.
    check a.peek() == 0
    check b.peek() == 20
    # Effect's body re-fired through the cascade; final reads track final values.
    check lastA == 0
    check lastB == 20
    # Sources/observers wiring intact — no orphans, no duplicates.
    check effect.sources.len == 2
    check Subscribable(a).observers.len == 1
    check Subscribable(b).observers.len == 1
    check Subscribable(a).observers[0] == effect
    check Subscribable(b).observers[0] == effect

  test "conditional read: rollback restores A's sign → final sources match":
    # Effect reads B only when A > 0. Speculative crosses the
    # conditional boundary in both directions; rollback restores A.
    # Final E.sources must reflect the final A value's branch.
    let a = signal(1)        # initially > 0 → effect should read B
    let b = signal(100)
    var reads = 0
    discard createRoot:
      createEffect proc() =
        inc reads
        if a() > 0:
          discard b()
        # else: don't read b — drop the subscription
    # Initial run subscribed to both.
    check Subscribable(a).observers.len == 1
    check Subscribable(b).observers.len == 1

    discard speculative:
      a.set(0)               # branch closes; effect re-runs, drops B subscription
      check Subscribable(b).observers.len == 0
      a.set(5)               # branch reopens; effect re-subscribes to B
      check Subscribable(b).observers.len == 1
      # exits without commit → rollback fires reverts in reverse:
      # revert a=5→0 (branch closes); revert a=0→1 (branch opens)

    # Final value of A is 1 (back to original). Branch open → B subscribed.
    check a.peek() == 1
    check Subscribable(a).observers.len == 1
    check Subscribable(b).observers.len == 1
    # No stale subscriptions left from the intermediate states.
    let effect = Subscribable(a).observers[0]
    check effect.sources.len == 2

  test "effect writing a derived signal during rollback drains cleanly":
    # Effect E reads `src`; whenever it fires, it sets `derived` =
    # src * 2. During a speculative rollback, E re-fires as src is
    # reverted — those re-fires push fresh reverts for `derived`
    # onto the same speculative frame. The rollback's `while
    # scope.reverts.len > 0` drains them all, producing a
    # consistent final state.
    let src = signal(10)
    let derived = signal(0)
    discard createRoot:
      createEffect proc() =
        derived.set(src() * 2)
    # Initial fire: derived = 20.
    check derived.peek() == 20

    discard speculative:
      src.set(7)
      # effect fires: derived.set(14). That set, happening inside the
      # speculative scope (not committed), records a revert for derived.
      check derived.peek() == 14
      src.set(3)
      check derived.peek() == 6
      # exits without commit → rollback

    # All reverts drained. Originals restored. Derived's reverts
    # (pushed during rollback's effect re-fires) also drained.
    check src.peek() == 10
    check derived.peek() == 20

    # No leftover reverts on the (now-committed) frame.
    # The substrate guarantees this via the while loop in rollback().
