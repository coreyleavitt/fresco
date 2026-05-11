{.experimental: "callOperator".}

import std/[unittest, strutils]
import fresco/screen
import fresco/reactive/scope
import fresco/reactive/signal
import fresco/reactive/binding

suite "bindRow":

  test "initial value is written to the row":
    let s = newScreen(5, 20)
    let r = newRegion(s, 0, 0, 3, 20)
    let title = signal("hello")
    discard createRoot:
      bindRow r, 0: title()
    check r.target[0] == "hello"

  test "writing the signal updates the row":
    let s = newScreen(5, 20)
    let r = newRegion(s, 0, 0, 3, 20)
    let title = signal("a")
    discard createRoot:
      bindRow r, 0: title()
    title.set("b")
    check r.target[0] == "b"
    title.set("c")
    check r.target[0] == "c"

  test "computed expression tracks multiple signals":
    let s = newScreen(5, 20)
    let r = newRegion(s, 0, 0, 3, 20)
    let count = signal(0)
    let total = signal(10)
    discard createRoot:
      bindRow r, 1: $count() & "/" & $total()
    check r.target[1] == "0/10"
    count.set(3)
    check r.target[1] == "3/10"
    total.set(20)
    check r.target[1] == "3/20"

  test "scope dispose stops the binding":
    let s = newScreen(5, 20)
    let r = newRegion(s, 0, 0, 3, 20)
    let label = signal("alpha")
    let root = createRoot:
      bindRow r, 0: label()
    check r.target[0] == "alpha"
    dispose(root)
    label.set("beta")
    check r.target[0] == "alpha"   # frozen at last value

  test "multiple bindRow on same region run independently":
    let s = newScreen(5, 20)
    let r = newRegion(s, 0, 0, 3, 20)
    let a = signal("A")
    let b = signal("B")
    discard createRoot:
      bindRow r, 0: a()
      bindRow r, 1: b()
    check r.target[0] == "A" and r.target[1] == "B"
    a.set("AA")
    check r.target == @["AA", "B"]
    b.set("BB")
    check r.target == @["AA", "BB"]

  test "out-of-range row index is silently dropped":
    let s = newScreen(5, 20)
    let r = newRegion(s, 0, 0, 2, 20)
    let v = signal("x")
    discard createRoot:
      bindRow r, 5: v()       # 5 > height(2) — no-op
    check r.target.len == 0

suite "bindRows":

  test "lays a seq[string] across the slice; updates on signal change":
    let s = newScreen(10, 20)
    let r = newRegion(s, 0, 0, 5, 20)
    let items = signal(@["one", "two", "three"])
    discard createRoot:
      bindRows r, 0 .. 4: items()
    check r.target == @["one", "two", "three", "", ""]
    items.set(@["a", "b"])
    check r.target == @["a", "b", "", "", ""]

  test "trailing slice entries blank when seq is shorter":
    let s = newScreen(10, 20)
    let r = newRegion(s, 0, 0, 5, 20)
    let items = signal(@["only-one"])
    discard createRoot:
      bindRows r, 1 .. 3: items()
    # Rows 1..3 set; row 0 and 4 untouched
    check r.target.len >= 4
    check r.target[1] == "only-one"
    check r.target[2] == ""
    check r.target[3] == ""
