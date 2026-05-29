## RenderTarget concept + binding abstraction (Split Phase 1).
##
## Bindings (`bindRow`, `bindRows`, `bindCollection`) used to take a
## concrete `Region`. They now take any value satisfying the
## `RenderTarget` concept — Region is the canonical impl, but other
## impls (headless driver, future fresco-web targets) can plug in.
##
## These tests verify the abstraction is real by exercising the
## bindings against a custom `InMemoryRenderTarget` defined inline
## (not Region).

import std/unittest
import intonaco/reactive/primitives/scope
import intonaco/reactive/primitives/signal
import intonaco/reactive/primitives/collection
import fresco/reactive/binding

# --- InMemoryRenderTarget: a non-Region implementation of the concept --
#
# Minimal data shape: a fixed-height rows buffer + width. setRow writes
# into the buffer. No Region machinery, no Screen, no terminal —
# proves the bindings don't secretly depend on any of those.

type
  InMemoryRenderTarget = ref object
    rows*: seq[string]
    height*: int
    width*: int

proc newInMemoryRenderTarget(height, width: int): InMemoryRenderTarget =
  InMemoryRenderTarget(
    rows: newSeq[string](height),
    height: height,
    width: width)

proc setRow*(t: InMemoryRenderTarget, idx: int, line: string) =
  if idx < 0 or idx >= t.height: return
  t.rows[idx] = line

# --- ScrollableTarget: a RenderTarget that also satisfies ScrollableRenderTarget ---
type
  ScrollableTarget = ref object
    rows*: seq[string]
    height*: int
    width*: int
    scrollCount*: int

proc setRow*(t: ScrollableTarget, idx: int, line: string) =
  if idx < 0 or idx >= t.height: return
  t.rows[idx] = line

proc scrollUp*(t: ScrollableTarget, n: int) =
  inc t.scrollCount, n

suite "RenderTarget: bindings work against a non-Region implementation":

  test "bindRow writes to a custom RenderTarget when its signal changes":
    let root = newScope()
    let target = newInMemoryRenderTarget(3, 40)
    withScope(root):
      let title = signalC("hello")
      bindRow target, 0, [title]: title
      check target.rows[0] == "hello"
      title.set("world")
      check target.rows[0] == "world"
    dispose(root)

  test "bindRows lays a multi-row slice into a custom RenderTarget":
    let root = newScope()
    let target = newInMemoryRenderTarget(5, 40)
    withScope(root):
      let items = signalC(@["a", "b", "c"])
      bindRows target, 0 .. 2, [items]: items
      check target.rows[0] == "a"
      check target.rows[1] == "b"
      check target.rows[2] == "c"
      items.set(@["x", "y"])
      check target.rows[0] == "x"
      check target.rows[1] == "y"
      check target.rows[2] == ""    # past-end row blanked
    dispose(root)

  test "bindCollection lays a CollectionSignal and applies deltas":
    let root = newScope()
    let target = newInMemoryRenderTarget(4, 40)
    withScope(root):
      let items = collectionC[string]()
      bindCollection(target, 0 .. 3, items, proc(s: string): string = s)
      # initial lay: empty
      check target.rows[0] == ""
      items.push("first")
      check target.rows[0] == "first"
      items.push("second")
      check target.rows[1] == "second"
      items.push("third")
      check target.rows[2] == "third"
    dispose(root)

  test "bindCollection wmFromEnd works on non-Scrollable target via slow-path repaint":
    # InMemoryRenderTarget has no scrollUp method. The wmFromEnd
    # fast-path falls back to a full repaint of the visible slice.
    # The visible content must be correct end-to-end.
    let root = newScope()
    let target = newInMemoryRenderTarget(3, 40)
    withScope(root):
      let items = collectionC[string]()
      bindCollection(target, 0 .. 2, items,
                     proc(s: string): string = s,
                     mode = wmFromEnd)
      items.push("1")
      items.push("2")
      items.push("3")
      # Now full — push another; wmFromEnd shifts the visible window.
      # Without scrollUp we still expect correct content.
      items.push("4")
      check target.rows[0] == "2"
      check target.rows[1] == "3"
      check target.rows[2] == "4"
    dispose(root)

  test "ScrollableRenderTarget receives scrollUp on wmFromEnd push when filled":
    # A target that implements scrollUp counts how many times the
    # fast-path fires. Pushing onto a not-yet-filled window: no
    # scrollUp (slow-path). Pushing on a filled window: one scrollUp
    # per push.
    let root = newScope()
    let target = ScrollableTarget(
      rows: newSeq[string](3), height: 3, width: 40, scrollCount: 0)
    withScope(root):
      let items = collectionC[string]()
      bindCollection(target, 0 .. 2, items,
                     proc(s: string): string = s,
                     mode = wmFromEnd)
      items.push("1")
      items.push("2")
      items.push("3")
      check target.scrollCount == 0       # window filling, not scrolling
      items.push("4")                     # filled now; fast-path fires
      check target.scrollCount == 1
      check target.rows[0] == "2"
      check target.rows[1] == "3"
      check target.rows[2] == "4"
    dispose(root)
