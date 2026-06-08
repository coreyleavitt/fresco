## Layout Region.set blank-fill tests — RFC surface-ownership slice 3.
##
## When Region.set is called with fewer content rows than the region's
## height, the trailing rows (content.len..height-1) must be explicitly
## blanked to "", so old content from a previous larger set doesn't linger.

import std/unittest
import fresco/render/layout

suite "Region.set blank-fills trailing rows on content shrink":

  test "tracer: shrink from 4 to 2 rows blanks rows 2 and 3":
    ## The core stale-on-shrink scenario.
    let layout = newLayout(height = 4, width = 20)
    let r = newRegion(layout, 0, 0, 4, 20)
    # Fill all 4 rows.
    r.set(["alpha", "beta", "gamma", "delta"])
    check r.rows.len == 4
    check r.rows[2] == "gamma"
    check r.rows[3] == "delta"
    # Now set only 2 rows — rows 2 and 3 must become "".
    r.set(["first", "second"])
    check r.rows.len == 4
    check r.rows[0] == "first"
    check r.rows[1] == "second"
    check r.rows[2] == ""
    check r.rows[3] == ""

  test "set with 0 rows blanks all height rows":
    let layout = newLayout(height = 3, width = 10)
    let r = newRegion(layout, 0, 0, 3, 10)
    r.set(["one", "two", "three"])
    r.set([])
    check r.rows.len == 3
    check r.rows[0] == ""
    check r.rows[1] == ""
    check r.rows[2] == ""

  test "set with exactly height rows blanks nothing":
    let layout = newLayout(height = 3, width = 10)
    let r = newRegion(layout, 0, 0, 3, 10)
    r.set(["a", "b", "c"])
    check r.rows.len == 3
    check r.rows[0] == "a"
    check r.rows[1] == "b"
    check r.rows[2] == "c"

  test "set with more than height rows truncates to height":
    let layout = newLayout(height = 2, width = 10)
    let r = newRegion(layout, 0, 0, 2, 10)
    r.set(["x", "y", "z", "w"])
    check r.rows.len == 2
    check r.rows[0] == "x"
    check r.rows[1] == "y"

  test "blank-fill marks region pending (dirty)":
    let layout = newLayout(height = 4, width = 20)
    let r = newRegion(layout, 0, 0, 4, 20)
    r.set(["a", "b", "c", "d"])
    r.pending = false          # manually clear dirty
    r.set(["only one"])        # trailing 3 rows become "" — must dirty
    check r.pending == true
