{.experimental: "callOperator".}

import std/[unittest, strutils]
import fresco/screen
import intonaco/reactive
import fresco/reactive/binding

suite "bindRow":

  test "initial value is written to the row":
    let s = newScreen(5, 20)
    let r = newRegion(s, 0, 0, 3, 20)
    signals:
      title = "hello"
    discard createRoot:
      bindRow r, 0, [title]: title
    check r.target[0] == "hello"

  test "writing the signal updates the row":
    let s = newScreen(5, 20)
    let r = newRegion(s, 0, 0, 3, 20)
    let title = signalC("a")
    discard createRoot:
      bindRow r, 0, [title]: title
    title.set("b")
    check r.target[0] == "b"
    title.set("c")
    check r.target[0] == "c"

  test "computed expression tracks multiple signals":
    let s = newScreen(5, 20)
    let r = newRegion(s, 0, 0, 3, 20)
    let count = signalC(0)
    let total = signalC(10)
    discard createRoot:
      bindRow r, 1, [count, total]: $count & "/" & $total
    check r.target[1] == "0/10"
    count.set(3)
    check r.target[1] == "3/10"
    total.set(20)
    check r.target[1] == "3/20"

  test "scope dispose stops the binding":
    let s = newScreen(5, 20)
    let r = newRegion(s, 0, 0, 3, 20)
    let label = signalC("alpha")
    let root = createRoot:
      bindRow r, 0, [label]: label
    check r.target[0] == "alpha"
    dispose(root)
    label.set("beta")
    check r.target[0] == "alpha"   # frozen at last value

  test "#68 regression: N>=3 bindRows on one signal all emit visibly":
    # The issue reporter's exact shape — three regions, three
    # bindRow effects observing one signal, signal write, paint,
    # flush bytes contain ALL three updated values. Pre-fix only
    # the first observer's setRow made it through.
    let s = newScreen(5, 20)
    let r1 = newRegion(s, 0, 0, 1, 20)
    let r2 = newRegion(s, 1, 0, 1, 20)
    let r3 = newRegion(s, 2, 0, 1, 20)
    let sig = signalC("a")
    discard createRoot:
      bindRow r1, 0, [sig]: "r1:" & sig
      bindRow r2, 0, [sig]: "r2:" & sig
      bindRow r3, 0, [sig]: "r3:" & sig
    discard s.flush()                   # drain initial paint
    sig.set("b")
    let after = s.flush()
    check after.contains("r1:b")
    check after.contains("r2:b")
    check after.contains("r3:b")        # ← the assertion that failed pre-fix

  test "multiple bindRow on same region run independently":
    let s = newScreen(5, 20)
    let r = newRegion(s, 0, 0, 3, 20)
    let a = signalC("A")
    let b = signalC("B")
    discard createRoot:
      bindRow r, 0, [a]: a
      bindRow r, 1, [b]: b
    check r.target[0] == "A" and r.target[1] == "B"
    a.set("AA")
    check r.target == @["AA", "B"]
    b.set("BB")
    check r.target == @["AA", "BB"]

  test "out-of-range row index is silently dropped":
    let s = newScreen(5, 20)
    let r = newRegion(s, 0, 0, 2, 20)
    let v = signalC("x")
    discard createRoot:
      bindRow r, 5, [v]: v       # 5 > height(2) — no-op
    check r.target.len == 0

suite "bindRows":

  test "lays a seq[string] across the slice; updates on signal change":
    let s = newScreen(10, 20)
    let r = newRegion(s, 0, 0, 5, 20)
    let items = signalC(@["one", "two", "three"])
    discard createRoot:
      bindRows r, 0 .. 4, [items]: items
    check r.target == @["one", "two", "three", "", ""]
    items.set(@["a", "b"])
    check r.target == @["a", "b", "", "", ""]

  test "trailing slice entries blank when seq is shorter":
    let s = newScreen(10, 20)
    let r = newRegion(s, 0, 0, 5, 20)
    let items = signalC(@["only-one"])
    discard createRoot:
      bindRows r, 1 .. 3, [items]: items
    # Rows 1..3 set; row 0 and 4 untouched
    check r.target.len >= 4
    check r.target[1] == "only-one"
    check r.target[2] == ""
    check r.target[3] == ""

suite "bindCollection":

  test "initial layout: rows populated from items[0]; formatter called once per item":
    let s = newScreen(10, 20)
    let r = newRegion(s, 0, 0, 5, 20)
    let c = collectionC(@[1, 2, 3])
    var fmtCalls = 0
    proc fmt(x: int): string =
      inc fmtCalls
      $x
    discard createRoot:
      bindCollection r, 0..<5, c, fmt
    check r.target == @["1", "2", "3", "", ""]
    check fmtCalls == 3

  test "push: one new item, one formatter call (acceptance #28)":
    # The load-bearing test: a single push() produces a single
    # setRow at the new item's row, not a full re-lay. We assert
    # this via formatter-call count — naive bindRows re-evaluates
    # every item per change.
    let s = newScreen(10, 20)
    let r = newRegion(s, 0, 0, 5, 20)
    let c = collectionC(@[1, 2, 3])
    var fmtCalls = 0
    proc fmt(x: int): string =
      inc fmtCalls
      $x
    discard createRoot:
      bindCollection r, 0..<5, c, fmt
    fmtCalls = 0    # reset after initial lay
    c.push(4)
    check r.target == @["1", "2", "3", "4", ""]
    check fmtCalls == 1

  test "pop: clears the freed row; zero new formatter calls":
    let s = newScreen(10, 20)
    let r = newRegion(s, 0, 0, 5, 20)
    let c = collectionC(@[10, 20, 30])
    var fmtCalls = 0
    proc fmt(x: int): string =
      inc fmtCalls
      $x
    discard createRoot:
      bindCollection r, 0..<5, c, fmt
    fmtCalls = 0
    discard c.pop()
    check r.target == @["10", "20", "", "", ""]
    check fmtCalls == 0     # no new formatting — pop is a structural op

  test "setAt: one row updated; one formatter call":
    let s = newScreen(10, 20)
    let r = newRegion(s, 0, 0, 5, 20)
    let c = collectionC(@[1, 2, 3])
    var fmtCalls = 0
    proc fmt(x: int): string =
      inc fmtCalls
      $x
    discard createRoot:
      bindCollection r, 0..<5, c, fmt
    fmtCalls = 0
    c.setAt(1, 99)
    check r.target == @["1", "99", "3", "", ""]
    check fmtCalls == 1

  test "insert in middle: trailing rows shift; one new formatter call":
    let s = newScreen(10, 20)
    let r = newRegion(s, 0, 0, 5, 20)
    let c = collectionC(@[1, 2, 3])
    var fmtCalls = 0
    proc fmt(x: int): string =
      inc fmtCalls
      $x
    discard createRoot:
      bindCollection r, 0..<5, c, fmt
    fmtCalls = 0
    c.insert(1, 99)
    check r.target == @["1", "99", "2", "3", ""]
    check fmtCalls == 1     # only the inserted item formatted

  test "remove in middle: trailing rows shift; zero formatter calls":
    let s = newScreen(10, 20)
    let r = newRegion(s, 0, 0, 5, 20)
    let c = collectionC(@[1, 2, 3, 4])
    var fmtCalls = 0
    proc fmt(x: int): string =
      inc fmtCalls
      $x
    discard createRoot:
      bindCollection r, 0..<5, c, fmt
    fmtCalls = 0
    c.remove(1)
    check r.target == @["1", "3", "4", "", ""]
    check fmtCalls == 0

  test "clear blanks every row in slice":
    let s = newScreen(10, 20)
    let r = newRegion(s, 0, 0, 5, 20)
    let c = collectionC(@[1, 2, 3])
    discard createRoot:
      bindCollection r, 0..<5, c, proc(x: int): string = $x
    c.clear()
    check r.target == @["", "", "", "", ""]

  test "set (replace): re-lays slice; formatter called per new item":
    let s = newScreen(10, 20)
    let r = newRegion(s, 0, 0, 5, 20)
    let c = collectionC(@[1, 2, 3])
    var fmtCalls = 0
    proc fmt(x: int): string =
      inc fmtCalls
      $x
    discard createRoot:
      bindCollection r, 0..<5, c, fmt
    fmtCalls = 0
    c.set(@[100, 200])
    check r.target == @["100", "200", "", "", ""]
    check fmtCalls == 2

  test "items exceed window: only first slice.len render":
    let s = newScreen(10, 20)
    let r = newRegion(s, 0, 0, 3, 20)
    let c = collectionC(@[1, 2, 3, 4, 5])
    var fmtCalls = 0
    proc fmt(x: int): string =
      inc fmtCalls
      $x
    discard createRoot:
      bindCollection r, 0..<3, c, fmt
    # Only the first 3 items get formatted into the visible window.
    check r.target == @["1", "2", "3"]
    check fmtCalls == 3     # NOT 5

  test "update beyond window: no setRow, no formatter call":
    let s = newScreen(10, 20)
    let r = newRegion(s, 0, 0, 3, 20)
    let c = collectionC(@[1, 2, 3, 4, 5])
    var fmtCalls = 0
    proc fmt(x: int): string =
      inc fmtCalls
      $x
    discard createRoot:
      bindCollection r, 0..<3, c, fmt
    fmtCalls = 0
    let before = r.target
    c.setAt(4, 99)              # idx 4 is off-screen (window is 0..<3)
    check r.target == before
    check fmtCalls == 0

  test "dkRollback after speculative scope re-lays correctly":
    let s = newScreen(10, 20)
    let r = newRegion(s, 0, 0, 5, 20)
    let c = collectionC(@[1, 2, 3])
    discard createRoot:
      bindCollection r, 0..<5, c, proc(x: int): string = $x
      discard speculative:
        c.push(4)
        c.push(5)
        c.setAt(0, 99)
        # body exits without commit → rollback
    # All speculative mutations reverted; cache + region back to initial.
    check c.get() == @[1, 2, 3]
    check r.target == @["1", "2", "3", "", ""]

  test "region DSL routes CollectionSignal body to bindCollection":
    # `rows A..B, []: collection` should dispatch to bindCollection
    # (differential), not bindRows (full re-eval).
    let s = newScreen(10, 20)
    let r = newRegion(s, 0, 0, 5, 20)
    let c = collectionC(@[1, 2, 3])
    discard createRoot:
      region(r):
        rows 0..4, []: c
    check r.target == @["1", "2", "3", "", ""]
    c.push(4)
    check r.target == @["1", "2", "3", "4", ""]

  test "region DSL routes Signal[seq[string]] body to bindRows":
    # Body is a string-yielding seq backed by a Signal — should go
    # through bindRows with the declared `items` dep.
    let s = newScreen(10, 20)
    let r = newRegion(s, 0, 0, 5, 20)
    let items = signalC(@["a", "b"])
    discard createRoot:
      region(r):
        rows 0..4, [items]: items
    check r.target == @["a", "b", "", "", ""]
    items.set(@["x"])
    check r.target == @["x", "", "", "", ""]

  test "scope death deregisters handler":
    let s = newScreen(10, 20)
    let r = newRegion(s, 0, 0, 3, 20)
    let c = collectionC(@[1, 2])
    let root = createRoot:
      bindCollection r, 0..<3, c, proc(x: int): string = $x
    check r.target == @["1", "2", ""]
    dispose(root)
    let before = r.target
    c.push(3)                   # should NOT update — handler deregistered
    check r.target == before

suite "bindCollection: wmFromEnd (tail-window, #41)":

  test "tracer: filled collection in wmFromEnd shows the LAST winLen items":
    # winLen = 3, items = [1..6]. wmFromStart would show [1,2,3];
    # wmFromEnd shows [4,5,6] — the last 3.
    let s = newScreen(10, 20)
    let r = newRegion(s, 0, 0, 3, 20)
    let c = collectionC(@[1, 2, 3, 4, 5, 6])
    proc fmt(x: int): string = $x
    discard createRoot:
      bindCollection(r, 0..<3, c, fmt, mode = wmFromEnd)
    check r.target == @["4", "5", "6"]

  test "wmFromEnd before fill: rows populate top-down from row 0":
    let s = newScreen(10, 20)
    let r = newRegion(s, 0, 0, 5, 20)
    let c = collectionC(@[10, 20])
    discard createRoot:
      bindCollection(r, 0..<5, c, proc(x: int): string = $x, mode = wmFromEnd)
    check r.target == @["10", "20", "", "", ""]

  test "push when filled shifts window forward by one":
    let s = newScreen(10, 20)
    let r = newRegion(s, 0, 0, 3, 20)
    let c = collectionC(@[1, 2, 3])
    discard createRoot:
      bindCollection(r, 0..<3, c, proc(x: int): string = $x, mode = wmFromEnd)
    check r.target == @["1", "2", "3"]
    c.push(4)
    check r.target == @["2", "3", "4"]   # 1 pushed off the top
    c.push(5)
    check r.target == @["3", "4", "5"]

  test "push before fill: appears at next row, no shift":
    let s = newScreen(10, 20)
    let r = newRegion(s, 0, 0, 5, 20)
    let c = collectionC(@[1, 2])
    discard createRoot:
      bindCollection(r, 0..<5, c, proc(x: int): string = $x, mode = wmFromEnd)
    c.push(3)
    check r.target == @["1", "2", "3", "", ""]   # still top-down
    c.push(4)
    check r.target == @["1", "2", "3", "4", ""]
    c.push(5)
    check r.target == @["1", "2", "3", "4", "5"]
    # Now filled; next push shifts.
    c.push(6)
    check r.target == @["2", "3", "4", "5", "6"]

  test "pop on overfilled collection reveals previously-off-screen item":
    let s = newScreen(10, 20)
    let r = newRegion(s, 0, 0, 3, 20)
    let c = collectionC(@[1, 2, 3, 4, 5])
    discard createRoot:
      bindCollection(r, 0..<3, c, proc(x: int): string = $x, mode = wmFromEnd)
    check r.target == @["3", "4", "5"]
    discard c.pop()
    # items now [1,2,3,4]; tail = [2,3,4]. Previously-off-screen 2 revealed.
    check r.target == @["2", "3", "4"]

  test "dkClear empties the window":
    let s = newScreen(10, 20)
    let r = newRegion(s, 0, 0, 3, 20)
    let c = collectionC(@[1, 2, 3, 4, 5])
    discard createRoot:
      bindCollection(r, 0..<3, c, proc(x: int): string = $x, mode = wmFromEnd)
    c.clear()
    check r.target == @["", "", ""]

  test "wmFromStart (default) regression: behavior unchanged":
    let s = newScreen(10, 20)
    let r = newRegion(s, 0, 0, 3, 20)
    let c = collectionC(@[1, 2, 3, 4, 5, 6])
    discard createRoot:
      bindCollection(r, 0..<3, c, proc(x: int): string = $x)   # no mode arg
    check r.target == @["1", "2", "3"]    # from-start: first 3

  test "ANSI emission: push on filled wmFromEnd emits scroll + one row, not N rows":
    # The #41 acceptance criterion: a single push on a filled
    # tail-window region produces a single visible-row update, not
    # winLen row repaints. Verified by counting CUP (cursor-to)
    # commands in the flush output:
    #   - Naive O(winLen) path would emit `winLen` CUP sequences
    #   - Optimized scroll path emits ONE CUP for the new bottom row
    #     (plus DECSTBM set/reset which use 'r' suffix, not 'H')
    let s = newScreen(10, 20)
    let r = newRegion(s, 0, 0, 5, 20)
    let c = collectionC(@[1, 2, 3, 4, 5])  # exactly fills winLen=5
    discard createRoot:
      bindCollection(r, 0..<5, c, proc(x: int): string = $x, mode = wmFromEnd)
    discard s.flush()    # drain initial-lay emissions

    c.push(6)
    let bytes = s.flush()

    # Count CUP terminators ('H') — each cursor-to ends with H.
    var cupCount = 0
    for ch in bytes:
      if ch == 'H': inc cupCount
    check cupCount == 1
    # Sanity: the scroll-region commands were emitted (DECSTBM uses 'r').
    check 'r' in bytes
    # Sanity: the new value made it into the bottom row.
    check r.target == @["2", "3", "4", "5", "6"]
