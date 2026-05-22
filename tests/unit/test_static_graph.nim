{.experimental: "callOperator".}

import std/[unittest, strformat]
import intonaco/reactive/scope
import intonaco/reactive/subscribable
import intonaco/reactive/signal
import intonaco/reactive/collection
import intonaco/reactive/static_graph

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

  test "tracked: detects CollectionSignal reads via .get and .len":
    # Regression for round-8 H3: previously isSignalRead matched only
    # Signal[T]; CollectionSignal[T] reads inside tracked: produced no
    # subscribe edge, so the block didn't re-run on mutations.
    let items = collection(@[1, 2, 3])
    var runs = 0
    discard createRoot:
      tracked:
        discard items.len
        inc runs
    check runs == 1
    items.push(4)        # mutation must fire the tracked block
    check runs == 2
    items.setAt(0, 99)
    check runs == 3

  test "tracked: subscribes reads inside implicit conversions":
    # Regression for round-9 H1: the walker used to `return` without
    # recursing on synthetic conversion nodes. A signal read wrapped
    # in an implicit coercion (here: int → Natural in a proc arg)
    # would be silently missed. After the fix, the walker visits
    # children of synthetic nodes.
    proc takesNat(n: Natural): int = int(n)
    let count = signal(0)
    var runs = 0
    discard createRoot:
      tracked:
        # count() returns int; takesNat takes Natural — Nim inserts
        # an nnkHiddenStdConv around count().
        discard takesNat(count())
        inc runs
    check runs == 1
    count.set(1)
    check runs == 2     # would fail (still 1) before round-9 H1

# --- #39: structural Subscribable detection -----------------------------

suite "tracked: type-system-driven detection (#39)":

  test "type alias of Signal[T] is detected via structural inheritance":
    # Pre-#39, the walker matched type names with getTypeInst, so an
    # alias `type AppCount = Signal[int]` resolved to the alias name
    # and didn't match "Signal" — silent under-subscription.
    # Post-#39, `when compiles(Subscribable(recv))` asks the type
    # system: aliases resolve, and inheritance is honored.
    type AppCount = Signal[int]
    let c: AppCount = signal(0)
    var runs = 0
    discard createRoot:
      tracked:
        discard c()
        inc runs
    check runs == 1
    c.set(1)
    check runs == 2   # would stay 1 under the old name-comparison detection

  test "user-defined Subscribable subtype is detected without macro edits":
    # Pre-#39, adding a third Subscribable subtype required editing
    # static_graph.nim's hardcoded `["Signal", "CollectionSignal"]`
    # name list. Post-#39, the macro asks the type system structurally
    # — no edit needed.
    type
      MyStore[T] = ref object of Subscribable
        val: T
    proc newStore[T](v: T): MyStore[T] = MyStore[T](val: v)
    proc get[T](s: MyStore[T]): T =
      trackRead(s)
      s.val
    proc `()`[T](s: MyStore[T]): T = s.get()
    proc set[T](s: MyStore[T], v: T) =
      s.val = v
      notify(s)

    let store = newStore(0)
    var runs = 0
    discard createRoot:
      tracked:
        discard store()
        inc runs
    check runs == 1
    store.set(7)
    check runs == 2

  test "non-Subscribable receiver does not subscribe":
    # `when compiles(Subscribable(recv))` filters out anything that
    # isn't a Subscribable subtype — int, string, user objects, etc.
    # The macro still walks the body; the type-system gate just drops
    # the subscribe emission for non-trackable calls.
    let count = signal(0)
    var runs = 0
    var s = "hello"
    discard createRoot:
      tracked:
        # `s.len()` is a call with a non-Subscribable receiver. It
        # should NOT cause the tracked body to subscribe to anything
        # other than `count`. (We verify by mutating only `count`
        # and seeing the expected re-fire count.)
        discard s.len
        discard count()
        inc runs
    check runs == 1
    count.set(5)
    check runs == 2
