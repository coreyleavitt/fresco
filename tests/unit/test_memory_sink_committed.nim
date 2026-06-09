## test_memory_sink_committed.nim — S0a: MemorySink.committedRows + runHeadless
## InlineScreen overload.
##
## RED → GREEN cycle for RFC-0011 S0a.
##
## Four test cases:
##   1. MemorySink.commitInline records committed batch into committedRows.
##   2. InlineScreen[MemorySink].commit() captures committed + paints live band.
##   3. teardownFlush on MemorySink also captures into committedRows.
##   4. runHeadless InlineScreen overload: both committedRows + rows retrievable.

{.experimental: "callOperator".}

import std/[unittest, strutils]
import chronos
import intonaco/reactive
import fresco/inline_screen
import fresco/render/layout
import fresco/render/sink/memory
import fresco/headless/runner
import fresco/events
import fresco/input
import fresco/headless/input as headless_input

# ---------------------------------------------------------------------------
# Suite 1: MemorySink.commitInline captures committed rows
# ---------------------------------------------------------------------------

suite "S0a: MemorySink.commitInline captures committed rows":

  test "commitInline appends committed batch to committedRows":
    ## After appendLine + commit, sink.committedRows contains the committed lines.
    let sink = newMemorySink()
    let s = newInlineScreen(sink, 10, 40)
    # Bottom-anchored: h=10, pinnedHeaderRows=1, liveZoneHeight=9 → row 1.
    let r = s.newRegion(1, 0, 9, 40)
    r.set(["live content"])
    s.appendLine("committed alpha")
    s.appendLine("committed beta")
    discard s.commit()
    check sink.committedRows.len == 2
    check sink.committedRows[0] == "committed alpha"
    check sink.committedRows[1] == "committed beta"

  test "committed lines are NOT duplicated into live rows":
    ## committedRows and rows are disjoint: committed lines must not appear in rows.
    let sink = newMemorySink()
    let s = newInlineScreen(sink, 10, 40)
    let r = s.newRegion(1, 0, 9, 40)
    r.set(["live line"])
    s.appendLine("committed only")
    discard s.commit()
    check sink.committedRows.contains("committed only")
    for row in sink.rows:
      check not row.contains("committed only")

  test "live band rows are captured in sink.rows after commit":
    ## The live band content is still accessible via sink.rows.
    let sink = newMemorySink()
    let s = newInlineScreen(sink, 10, 40)
    let r = s.newRegion(1, 0, 9, 40)
    r.set(["hello from live"])
    s.appendLine("a committed line")
    discard s.commit()
    check sink.rows.len == 10
    check sink.rows[1] == "hello from live"

  test "multiple commit calls accumulate committedRows":
    ## Second commit adds to committedRows (does not reset to empty).
    let sink = newMemorySink()
    let s = newInlineScreen(sink, 10, 40)
    let r = s.newRegion(1, 0, 9, 40)
    r.set(["live"])
    s.appendLine("first")
    discard s.commit()
    s.appendLine("second")
    discard s.commit()
    check sink.committedRows.len == 2
    check sink.committedRows[0] == "first"
    check sink.committedRows[1] == "second"

# ---------------------------------------------------------------------------
# Suite 2: teardownFlush also captures committed lines
# ---------------------------------------------------------------------------

suite "S0a: MemorySink teardownFlush captures committed rows":

  test "teardownFlush drains pending committed lines into committedRows":
    let sink = newMemorySink()
    let s = newInlineScreen(sink, 10, 40)
    let r = s.newRegion(1, 0, 9, 40)
    r.set(["live"])
    s.appendLine("teardown line")
    check s.logPendingLen() == 1
    teardownFlush(s)
    check s.logPendingLen() == 0
    check sink.committedRows.len == 1
    check sink.committedRows[0] == "teardown line"

# ---------------------------------------------------------------------------
# Suite 3: HeadlessResult.committedRows
# ---------------------------------------------------------------------------

suite "S0a: HeadlessResult.committedRows field":

  test "HeadlessResult has committedRows field":
    ## Compile-time: the field exists and is a seq[string].
    var r: HeadlessResult
    r.committedRows = @["test"]
    check r.committedRows.len == 1

# ---------------------------------------------------------------------------
# Suite 4: runHeadless InlineScreen overload
# ---------------------------------------------------------------------------

suite "S0a: runHeadless InlineScreen[MemorySink] overload":

  test "runHeadless with InlineScreen: committedRows and rows both captured":
    ## Build an InlineScreen[MemorySink], run an app that appends committed
    ## lines and sets live-band content, then check both are retrievable.
    proc body() {.async: (raises: [Exception]).} =
      let sink = newMemorySink()
      let s = newInlineScreen(sink, 10, 40)
      # Bottom-anchored region.
      let r = s.newRegion(1, 0, 9, 40)

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        r.set(["live content"])
        s.appendLine("committed line 1")
        s.appendLine("committed line 2")
        discard s.commit()

      let result = await runHeadless(s, app, events = @[])
      check result.committedRows.len == 2
      check result.committedRows[0] == "committed line 1"
      check result.committedRows[1] == "committed line 2"
      check result.rows[1] == "live content"
    waitFor body()

  test "runHeadless InlineScreen overload: existing runHeadless still works":
    ## The old (app, layout) overload must still compile and work.
    proc app(stream: InputStream, layout: Layout) {.async: (raises: [Exception]).} =
      let r = newRegion(layout, 0, 0, 2, 20)
      r.set(["alpha", "beta"])
      # no quit key — harness cancels at timeout

    proc body() {.async: (raises: [Exception]).} =
      let result = await runHeadless(app, inputs = @[], height = 2, width = 20)
      check result.rows[0] == "alpha"
      check result.rows[1] == "beta"
    waitFor body()
