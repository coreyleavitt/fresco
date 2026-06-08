## Layout Region.set / setRow clip chokepoint tests — RFC surface-ownership slice 2b.
##
## Every row written through Region.set or Region.setRow must be
## clipped to r.width columns at the point of write. Tests here
## verify that invariant, the setRowChecked escape hatch, and
## the `target` privatisation compile-barrier.

import std/unittest
import fresco/render/layout
import fresco/terminal/ansi

suite "Region.set clips rows to r.width":

  test "set: a row wider than r.width is stored clipped":
    let layout = newLayout(height = 3, width = 10)
    let r = newRegion(layout, 0, 0, 3, 10)
    r.set(["hello world this is way too long"])
    check displayWidth(r.rows[0]) <= r.width

  test "set: a row exactly r.width wide is stored unchanged":
    let layout = newLayout(height = 1, width = 5)
    let r = newRegion(layout, 0, 0, 1, 5)
    r.set(["hello"])
    check r.rows[0] == "hello"

  test "set: a row shorter than r.width is stored unchanged":
    let layout = newLayout(height = 1, width = 20)
    let r = newRegion(layout, 0, 0, 1, 20)
    r.set(["hi"])
    check r.rows[0] == "hi"

  test "set: multiple rows each clipped independently":
    let layout = newLayout(height = 3, width = 5)
    let r = newRegion(layout, 0, 0, 3, 5)
    r.set(["abcdefghij", "xy", "12345678"])
    check displayWidth(r.rows[0]) <= r.width
    check r.rows[1] == "xy"
    check displayWidth(r.rows[2]) <= r.width

suite "Region.setRow clips a single row to r.width":

  test "setRow: an over-wide line is stored clipped":
    let layout = newLayout(height = 3, width = 8)
    let r = newRegion(layout, 0, 0, 3, 8)
    r.setRow(0, "hello world")
    check displayWidth(r.rows[0]) <= r.width

  test "setRow: a within-width line is stored unchanged":
    let layout = newLayout(height = 3, width = 20)
    let r = newRegion(layout, 0, 0, 3, 20)
    r.setRow(1, "fits fine")
    check r.rows[1] == "fits fine"

suite "Region.setRowChecked escape hatch":

  test "setRowChecked stores a within-width line without re-clipping":
    let layout = newLayout(height = 3, width = 20)
    let r = newRegion(layout, 0, 0, 3, 20)
    r.setRowChecked(0, "already ok")
    check r.rows[0] == "already ok"

  when compileOption("assertions"):
    test "setRowChecked asserts on an over-wide line":
      let layout = newLayout(height = 3, width = 5)
      let r = newRegion(layout, 0, 0, 3, 5)
      var panicked = false
      try:
        r.setRowChecked(0, "toolong")
      except AssertionDefect:
        panicked = true
      check panicked
