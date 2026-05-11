import std/unittest
import fresco/screen
import fresco/layout

suite "splitRows":

  test "equal weights divide evenly":
    check splitRows(10, [1, 1]) == @[(0, 5), (5, 5)]

  test "uneven weights are proportional; last slot absorbs remainder":
    check splitRows(10, [1, 2, 1]) == @[(0, 2), (2, 5), (7, 3)]

  test "single weight gets the whole area":
    check splitRows(10, [7]) == @[(0, 10)]

  test "zero total height yields zero-sized slots":
    check splitRows(0, [1, 2]) == @[(0, 0), (0, 0)]

suite "VStack":

  test "creates regions sized by weight":
    let s = newScreen(20, 80)
    let v = newVStack(s, weights = [1, 2, 1])
    check v.regions.len == 3
    check v.regions[0].row == 0  and v.regions[0].height == 5
    check v.regions[1].row == 5  and v.regions[1].height == 10
    check v.regions[2].row == 15 and v.regions[2].height == 5
    # Widths all match the layout area.
    for r in v.regions:
      check r.col == 0
      check r.width == 80

  test "explicit area with offset":
    let s = newScreen(20, 80)
    let v = newVStack(s, weights = [1, 1],
                     top = 4, left = 10,
                     height = 8, width = 30)
    check v.regions[0].row == 4 and v.regions[0].height == 4
    check v.regions[1].row == 8 and v.regions[1].height == 4
    for r in v.regions:
      check r.col == 10
      check r.width == 30

  test "relayout after screen resize redistributes":
    let s = newScreen(10, 80)
    let v = newVStack(s, weights = [1, 1])
    check v.regions[0].height == 5
    s.height = 20
    v.relayout()
    check v.regions[0].height == 10
    check v.regions[1].row == 10
    check v.regions[1].height == 10
