import std/unittest
import fresco/render
import fresco/terminal/ansi

suite "Renderer diff":

  test "first render emits all rows":
    let r = newRenderer(5, 20)
    let bytes = r.render(0, 0, ["hello", "world"])
    check bytes == cursorTo(1, 1) & clearLineRight() & "hello" &
                 cursorTo(2, 1) & clearLineRight() & "world"

  test "rendering the same content twice emits nothing the second time":
    let r = newRenderer(5, 20)
    discard r.render(1, 3, ["abc"])
    check r.render(1, 3, ["abc"]) == ""

  test "changed rows are emitted; unchanged rows are skipped":
    let r = newRenderer(5, 20)
    discard r.render(0, 0, ["one", "two", "three"])
    let bytes = r.render(0, 0, ["one", "TWO", "three"])
    check bytes == cursorTo(2, 1) & clearLineRight() & "TWO"

  test "invalidate forces full re-emission":
    let r = newRenderer(5, 20)
    discard r.render(0, 0, ["a", "b"])
    r.invalidate()
    let bytes = r.render(0, 0, ["a", "b"])
    check bytes == cursorTo(1, 1) & clearLineRight() & "a" &
                 cursorTo(2, 1) & clearLineRight() & "b"

  test "rows past height are clipped silently":
    let r = newRenderer(2, 20)
    let bytes = r.render(1, 0, ["row1", "row2-clipped"])
    # absRow 1 fits; absRow 2 does not (height is 2 → rows 0 and 1).
    check bytes == cursorTo(2, 1) & clearLineRight() & "row1"

  test "non-zero column offset is encoded in CUP":
    let r = newRenderer(3, 40)
    let bytes = r.render(0, 10, ["x"])
    check bytes == cursorTo(1, 11) & clearLineRight() & "x"

  test "resize drops cached snapshot":
    let r = newRenderer(3, 20)
    discard r.render(0, 0, ["same"])
    r.resize(5, 30)
    check r.render(0, 0, ["same"]) != ""
