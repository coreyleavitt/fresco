import std/unittest
import fresco/screen
import fresco/scrollback

proc viewportTexts(s: Scrollback): seq[string] =
  ## After render(), pull the target the region was set with.
  ## We rely on the renderer's diff cache: rendering and then diffing
  ## the target shows what we'd actually show on screen.
  s.render()
  # Read via the region's internal target field — exposed via flush
  # would also work but this is more direct for assertion purposes.
  for line in s.region.target: result.add line

# Helper: hand-roll a screen + region of given height.
proc rig(height: int): Scrollback =
  let screen = newScreen(20, 40)
  let region = newRegion(screen, row = 0, col = 0,
                         height = height, width = 40)
  newScrollback(region, maxLines = 100)

suite "Scrollback":

  test "fewer lines than height: top rows are blank, bottom holds content":
    let s = rig(4)
    s.append "one"
    s.append "two"
    let v = viewportTexts(s)
    check v == @["", "", "one", "two"]

  test "more lines than height: bottom N visible, tail-mode pinned":
    let s = rig(3)
    for i in 1 .. 5: s.append "line" & $i
    check viewportTexts(s) == @["line3", "line4", "line5"]

  test "scrollUp walks history; scrollDown returns to tail":
    let s = rig(3)
    for i in 1 .. 6: s.append "line" & $i
    s.scrollUp(2)
    check viewportTexts(s) == @["line2", "line3", "line4"]
    check s.browsing
    s.scrollDown(2)
    check viewportTexts(s) == @["line4", "line5", "line6"]
    check not s.browsing
    check s.atBottom

  test "scrollUp clamps at top of history":
    let s = rig(3)
    for i in 1 .. 5: s.append "line" & $i
    s.scrollUp(100)
    # maxOffset = lines.len(5) - height(3) = 2
    check s.offset == 2
    check viewportTexts(s) == @["line1", "line2", "line3"]

  test "maxLines drops oldest; offset shifts so the view doesn't jump":
    let screen = newScreen(20, 40)
    let region = newRegion(screen, 0, 0, 3, 40)
    let s = newScrollback(region, maxLines = 5)
    for i in 1 .. 5: s.append "line" & $i
    s.scrollUp(2)
    check viewportTexts(s) == @["line1", "line2", "line3"]
    # Drop oldest by appending past the cap. line1 falls off.
    s.append "line6"
    # offset was 2, drop = 1, new offset = 1 → window of (line2..line4)
    check viewportTexts(s) == @["line2", "line3", "line4"]

  test "enterBrowse / exitBrowse toggles state without touching offset":
    let s = rig(3)
    for i in 1 .. 5: s.append "line" & $i
    s.enterBrowse()
    check s.browsing
    check s.offset == 0  # still at bottom; browse is a mode flag
    s.exitBrowse()
    check not s.browsing
    check s.offset == 0

  test "scrollToBottom jumps to live tail":
    let s = rig(3)
    for i in 1 .. 6: s.append "line" & $i
    s.scrollUp(2)
    s.scrollToBottom()
    check s.offset == 0
    check viewportTexts(s) == @["line4", "line5", "line6"]
