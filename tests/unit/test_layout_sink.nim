## Layout + Sink (Split Phase 2).
##
## Layout is the multi-region spatial coordinator extracted from
## Screen. Sink is the commit target — TerminalSink emits ANSI to a
## file descriptor; MemorySink captures rendered content in-memory
## for testing/CI/notebook/sidecar consumers.
##
## These tests verify the abstraction is real by exercising it
## without any reference to Screen.

import std/unittest
import intonaco/reactive
import fresco/reactive/binding
import fresco/render/layout
import fresco/render/sink
import fresco/render/sink/memory

suite "Layout + MemorySink: headless rendering substrate":

  test "bindings on a Layout region commit to MemorySink captured rows":
    let root = newScope()
    let layout = newLayout(height = 3, width = 40)
    let region = newRegion(layout, 0, 0, 3, 40)
    let sink = newMemorySink()
    withScope(root):
      let title {.height: 0.} = signalC("hello")
      bindRow region, 0, [title]: title
      bindRow region, 1, []: "world"
      sink.commit(layout)
      check sink.rows[0] == "hello"
      check sink.rows[1] == "world"
      title.set("changed")
      sink.commit(layout)
      check sink.rows[0] == "changed"
    dispose(root)

  test "any type that exposes commit(Layout) satisfies the Sink concept":
    # A custom sink — demonstrates Sink isn't MemorySink-coupled.
    # The concept is structural: any type with the right commit shape
    # satisfies it. No inheritance, no marker types, no registration.
    type CountingSink = ref object
      commitCount: int
    proc commit(s: CountingSink, l: Layout) =
      inc s.commitCount

    static:
      doAssert CountingSink is Sink
      doAssert MemorySink is Sink

    let layout = newLayout(height = 2, width = 10)
    let s = CountingSink()
    s.commit(layout)
    s.commit(layout)
    check s.commitCount == 2

  test "multi-region Layout: each region paints into its own rows":
    # Three stacked regions, each one row tall. Sink captures the
    # composed view — each row's content comes from the region
    # covering it.
    let root = newScope()
    let layout = newLayout(height = 3, width = 20)
    let topR    = newRegion(layout, 0, 0, 1, 20)
    let middleR = newRegion(layout, 1, 0, 1, 20)
    let bottomR = newRegion(layout, 2, 0, 1, 20)
    let sink = newMemorySink()
    withScope(root):
      let status {.height: 0.} = signalC("ready")
      bindRow topR, 0, []:    "header"
      bindRow middleR, 0, [status]: status
      bindRow bottomR, 0, []: "footer"
      sink.commit(layout)
      check sink.rows[0] == "header"
      check sink.rows[1] == "ready"
      check sink.rows[2] == "footer"
      status.set("working")
      sink.commit(layout)
      check sink.rows[1] == "working"
      check sink.rows[0] == "header"     # unchanged
      check sink.rows[2] == "footer"     # unchanged
    dispose(root)
