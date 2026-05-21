## Screen v2 — reactive size signal (#98).
##
## Asserts that Screen exposes its dimensions as a reactive
## Signal[(int, int)], not just mutable fields. Subscribers to
## `screen.size` re-run when dimensions change.

{.experimental: "callOperator".}

import std/[unittest, posix]
import chronos
import fresco/screen
import fresco/reactive/signal
import fresco/reactive/scope

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
      createEffect:
        observed.add(s.size())
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
        createEffect:
          observed.add(s.size())
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
