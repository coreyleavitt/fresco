## Screen v2 — reactive size signal (#98).
##
## Asserts that Screen exposes its dimensions as a reactive
## Signal[(int, int)], not just mutable fields. Subscribers to
## `screen.size` re-run when dimensions change.

{.experimental: "callOperator".}

import std/[unittest, posix]
import chronos
import fresco/screen
import intonaco/reactive

var SIGWINCH {.importc, header: "<signal.h>".}: cint

suite "Screen v2: reactive size signal":

  test "size starts at construction-time dimensions":
    let s = newScreen(24, 80)
    check s.size() == (24, 80)

  test "setSize writes the signal so subscribers re-run":
    let s = newScreen(24, 80)
    let root = newScope()
    var observed: seq[(int, int)]
    withScope(root):
      let sizeSig = s.size
      effect [sizeSig]:
        observed.add(sizeSig)
    check observed == @[(24, 80)]
    setSize(s, 30, 100)
    check observed == @[(24, 80), (30, 100)]
    dispose(root)

  test "setSize clamps regions overflowing new dimensions":
    let s = newScreen(10, 20)
    let r = newRegion(s, row = 5, col = 0, height = 5, width = 20)
    r.set(["a", "b", "c", "d", "e"])
    check r.target.len == 5
    # Shrink the terminal so the region overflows the new height.
    setSize(s, 7, 20)
    check r.height == 2          # 7 - 5 (row) = 2
    check r.target.len == 2       # target truncated to fit

  test "setSize clamps a region whose origin is now outside the screen":
    let s = newScreen(10, 20)
    let r = newRegion(s, row = 8, col = 0, height = 2, width = 20)
    setSize(s, 5, 20)
    check r.height == 0           # row 8 is past new height 5

  test "setSize invalidates the sink's render cache":
    # Bytes emitted on flush after setSize should be non-empty even if
    # nothing about the region changed — the renderer can't trust its
    # cache after a resize (the terminal contents are now unknown).
    let s = newScreen(10, 20)
    let r = newRegion(s, 0, 0, 1, 20)
    r.set(["hello"])
    discard s.flush()             # first flush primes cache + emits
    check s.flush() == ""         # no changes → no bytes
    setSize(s, 10, 20)            # same dims, but cache should reset
    check s.flush().len > 0

  test "watchResizes writes the signal when SIGWINCH fires":
    proc inner(): Future[void] {.async: (raises: [Exception]).} =
      let s = newScreen(10, 20)
      installResizeHandler()
      defer: uninstallResizeHandler()

      var observed: seq[(int, int)]
      let root = newScope()
      defer: dispose(root)
      withScope(root):
        let sizeSig = s.size
        effect [sizeSig]:
          observed.add(sizeSig)
      check observed == @[(10, 20)]

      let watcher = watchResizes(s)
      defer: watcher.cancelSoon()

      # Raise SIGWINCH to ourselves; the handler sets the pending flag;
      # watchResizes picks it up on its next poll and calls setSize.
      # queryWinsize falls back to (24, 80) when fd 2 isn't a TTY (CI).
      discard kill(getpid(), SIGWINCH)
      # Allow the polling task at least one tick to observe and dispatch.
      await sleepAsync(200.milliseconds)

      check observed.len >= 2
      check observed[^1] != (10, 20)   # signal changed away from initial

    waitFor inner()

import fresco/render/sink/memory
import fresco/render/layout

suite "Screen v2: sink-polymorphic Screen[S]":

  test "Screen[MemorySink] constructs with size signal at given dims":
    let mem = newMemorySink()
    let s = newScreen(mem, 5, 20)
    check s.size() == (5, 20)
    check s.layout.height == 5
    check s.layout.width == 20

  test "paint(memoryScreen) captures bound content via MemorySink":
    let mem = newMemorySink()
    let s = newScreen(mem, 3, 10)
    let r = newRegion(s, 0, 0, 3, 10)
    r.set(["alpha", "beta", "gamma"])
    paint(s)
    check mem.rows.len == 3
    check mem.rows[0] == "alpha"
    check mem.rows[1] == "beta"
    check mem.rows[2] == "gamma"

  test "ScreenLike concept matches both TerminalScreen and MemoryScreen":
    # Pure compile-time check: any proc taking ScreenLike accepts both
    # variants. If this compiles, the concept is wired correctly.
    proc takesScreenLike[T: ScreenLike](s: T): int = s.layout.height
    let t = newScreen(5, 20)
    let m = newScreen(newMemorySink(), 3, 10)
    check takesScreenLike(t) == 5
    check takesScreenLike(m) == 3

  test "setSize on MemoryScreen clamps regions and writes signal":
    let mem = newMemorySink()
    let s = newScreen(mem, 10, 20)
    let r = newRegion(s, 5, 0, 5, 20)
    r.set(["a", "b", "c", "d", "e"])
    var observed: seq[(int, int)]
    let root = newScope()
    defer: dispose(root)
    withScope(root):
      let sizeSig = s.size
      effect [sizeSig]:
        observed.add(sizeSig)
    setSize(s, 7, 20)
    check r.height == 2          # 7 - 5 = 2
    check r.target.len == 2       # truncated
    check observed[^1] == (7, 20) # signal updated

suite "Screen v2: auto-paint":

  test "runAutoPaint paints within one tick after a dirty mark":
    proc inner(): Future[void] {.async: (raises: [Exception]).} =
      let mem = newMemorySink()
      let s = newScreen(mem, 2, 10)
      let r = newRegion(s, 0, 0, 2, 10)
      let painter = runAutoPaint(s)
      defer: painter.cancelSoon()
      check mem.rows.len == 0   # nothing committed yet
      r.set(["hello", "world"])
      await sleepAsync(80.milliseconds)  # > one 33ms tick
      check mem.rows.len == 2
      check mem.rows[0] == "hello"
      check mem.rows[1] == "world"
    waitFor inner()

  test "runAutoPaint is a no-op when no region is dirty":
    proc inner(): Future[void] {.async: (raises: [Exception]).} =
      let mem = newMemorySink()
      let s = newScreen(mem, 2, 10)
      discard newRegion(s, 0, 0, 2, 10)  # region exists but not set
      let painter = runAutoPaint(s)
      defer: painter.cancelSoon()
      await sleepAsync(100.milliseconds)  # ~3 ticks
      check mem.rows.len == 0   # paint was never called
    waitFor inner()

  test "cancelling runAutoPaint stops the auto-paint loop":
    proc inner(): Future[void] {.async: (raises: [Exception]).} =
      let mem = newMemorySink()
      let s = newScreen(mem, 1, 10)
      let r = newRegion(s, 0, 0, 1, 10)
      let painter = runAutoPaint(s)
      r.set(["first"])
      await sleepAsync(80.milliseconds)
      check mem.rows[0] == "first"
      painter.cancelSoon()
      await sleepAsync(20.milliseconds)  # let cancellation propagate
      # After cancel, subsequent dirty marks should NOT trigger paint.
      r.set(["second"])
      await sleepAsync(100.milliseconds)
      check mem.rows[0] == "first"  # MemorySink wasn't called again
    waitFor inner()

  test "two Screens have independent runAutoPaint tasks":
    proc inner(): Future[void] {.async: (raises: [Exception]).} =
      let memA = newMemorySink()
      let memB = newMemorySink()
      let sA = newScreen(memA, 1, 10)
      let sB = newScreen(memB, 1, 10)
      let rA = newRegion(sA, 0, 0, 1, 10)
      let rB = newRegion(sB, 0, 0, 1, 10)
      let pA = runAutoPaint(sA)
      let pB = runAutoPaint(sB)
      defer:
        pA.cancelSoon()
        pB.cancelSoon()
      rA.set(["A"])
      rB.set(["B"])
      await sleepAsync(80.milliseconds)
      check memA.rows[0] == "A"
      check memB.rows[0] == "B"
    waitFor inner()
