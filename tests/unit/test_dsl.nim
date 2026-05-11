## DSL sugar tests — state + := operator.

{.experimental: "callOperator".}

import std/unittest
import fresco/screen
import fresco/reactive/scope
import fresco/reactive/signal
import fresco/reactive/binding

suite "DSL: state block":

  test "declares multiple signals in one block":
    signals:
      count = 0
      title = "hello"
      ratio = 3.14
    check count() == 0
    check title() == "hello"
    check ratio() == 3.14

  test "declared signals participate in effects normally":
    signals:
      a = 1
      b = 2
    var sums: seq[int] = @[]
    discard createRoot:
      createEffect proc() = sums.add a() + b()
    a := 10
    b := 20
    check sums == @[3, 12, 30]

suite "DSL: := operator":

  test ":= writes the signal and re-fires effects":
    let count = signal(0)
    var seenVals: seq[int] = @[]
    discard createRoot:
      createEffect proc() = seenVals.add count()
    count := 1
    count := 2
    count := 3
    check seenVals == @[0, 1, 2, 3]

  test ":= short-circuits when value unchanged":
    let count = signal(5)
    var runs = 0
    discard createRoot:
      createEffect proc() =
        discard count()
        inc runs
    check runs == 1
    count := 5            # no change
    check runs == 1
    count := 6
    check runs == 2

  test ":= works with custom types":
    type Item = object
      label: string
    let item = signal(Item(label: "x"))
    check item().label == "x"
    item := Item(label: "y")
    check item().label == "y"

suite "DSL: region block":

  test "row arms bind the listed rows":
    let s = newScreen(5, 20)
    let r = newRegion(s, 0, 0, 3, 20)
    let title = signal("hello")
    let count = signal(0)
    discard createRoot:
      region(r):
        row 0: title()
        row 1: $count()
    check r.target[0] == "hello"
    check r.target[1] == "0"
    title := "world"
    check r.target[0] == "world"
    count := 5
    check r.target[1] == "5"

  test "rows arm binds a slice from a seq signal":
    let s = newScreen(10, 20)
    let r = newRegion(s, 0, 0, 5, 20)
    let items = signal(@["a", "b", "c"])
    discard createRoot:
      region(r):
        row 0: "header"
        rows 1..3: items()
    check r.target == @["header", "a", "b", "c"]
    items := @["x", "y"]
    check r.target == @["header", "x", "y", ""]

  test "row index can be a computed expression":
    let s = newScreen(5, 20)
    let r = newRegion(s, 0, 0, 3, 20)
    let footer = signal("end")
    discard createRoot:
      region(r):
        row r.height - 1: footer()
    check r.target[2] == "end"
    footer := "stop"
    check r.target[2] == "stop"
