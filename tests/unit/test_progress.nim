import std/[unittest, strutils]
import fresco/screen
import fresco/widgets/progress
import fresco/terminal/ansi

proc rig(rows: int): ProgressGroup =
  let s = newScreen(20, 60)
  let r = newRegion(s, 0, 0, rows, 60)
  newProgressGroup(r)

suite "Progress group":

  test "addItem creates a running item":
    let g = rig(4)
    let a = g.addItem("install")
    check a.state == psRunning
    check a.label == "install"
    check g.items.len == 1

  test "render produces one row per item; extras are blank":
    let g = rig(4)
    discard g.addItem("a")
    discard g.addItem("b")
    g.render()
    check g.region.target.len == 4
    check "a" in g.region.target[0]
    check "b" in g.region.target[1]
    check g.region.target[2] == ""
    check g.region.target[3] == ""

  test "spinner glyph rotates on advanceTick":
    let g = rig(2)
    discard g.addItem("x")
    g.render()
    let first = g.region.target[0]
    g.advanceTick()
    g.render()
    let second = g.region.target[0]
    check first != second

  test "complete switches to done glyph; fail to failed glyph":
    let g = rig(3)
    let a = g.addItem("ok")
    let b = g.addItem("bad")
    complete(a, "200")
    fail(b, "503")
    g.render()
    check "v" in g.region.target[0]
    check "200" in g.region.target[0]
    check "x" in g.region.target[1]
    check "503" in g.region.target[1]

  test "more items than rows are clipped":
    let g = rig(2)
    discard g.addItem("a")
    discard g.addItem("b")
    discard g.addItem("c")
    g.render()
    check g.region.target.len == 2
    check "a" in g.region.target[0]
    check "b" in g.region.target[1]

  test "setDetail updates the dim suffix":
    let g = rig(2)
    let a = g.addItem("download")
    setDetail(a, "12%")
    g.render()
    check "12%" in g.region.target[0]
