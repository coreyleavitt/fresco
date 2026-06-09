## test_inline_screen.nim — Slice 7: InlineScreen + private ScrollbackLog
## behind LogSink capability + ScreenView.
##
## Four test groups per the slice spec:
##   1. Pinned-region regression: paint bytes identical to Screen[S] path.
##   2. Capability split: LogSink exposes `append` (positive witness) and
##      provably blocks `takeBatch`/`.log` access (single-writer structural).
##   3. liveZoneHeight derivation: correct initial value + max(0,…) clamp.
##   4. Enqueue + buffer: append through LogSink buffers lines; verified
##      via InlineScreen pipeline accessors (logPendingLen / logDrainBatch).

{.experimental: "callOperator".}

import std/unittest
import fresco/render/sink/memory
import fresco/render/layout
import fresco/screen
import fresco/inline_screen
import intonaco/reactive

# Helper: make a fresh MemorySink InlineScreen
proc makeMemScreen11(h, w: int, pinnedHeaderRows = 1): InlineScreen[MemorySink] =
  let sink = newMemorySink()
  newInlineScreen(sink, h, w, pinnedHeaderRows)

suite "InlineScreen slice 7: pinned-region regression":

  test "paint via InlineScreen[MemorySink] matches Screen[MemorySink] output":
    # Both screens: 5 rows tall, 20 cols wide, one full-surface region.
    # Set the same content and paint. Assert MemorySink.rows are identical.
    let mem1 = newMemorySink()
    let s1 = newScreen(mem1, 5, 20)
    let r1 = newRegion(s1, 0, 0, 5, 20)
    r1.set(["alpha", "beta", "gamma", "delta", "epsilon"])
    paint(s1)

    let mem2 = newMemorySink()
    let s2 = newInlineScreen(mem2, 5, 20, pinnedHeaderRows = 1)
    let r2 = newRegion(s2, 0, 0, 5, 20)
    r2.set(["alpha", "beta", "gamma", "delta", "epsilon"])
    paint(s2)

    # Pinned rendering must be byte-identical.
    check mem2.rows.len == mem1.rows.len
    for i in 0 ..< mem1.rows.len:
      check mem2.rows[i] == mem1.rows[i]

  test "newRegion on InlineScreen within layout bounds succeeds":
    let mem = newMemorySink()
    let s = newInlineScreen(mem, 10, 40, pinnedHeaderRows = 1)
    let r = newRegion(s, 0, 0, 2, 40)
    check r.row == 0
    check r.height == 2
    check s.layout.regions.len == 1

  test "paint captures content into MemorySink rows":
    let mem = newMemorySink()
    let s = newInlineScreen(mem, 3, 10, pinnedHeaderRows = 1)
    let r = newRegion(s, 0, 0, 3, 10)
    r.set(["foo", "bar", "baz"])
    paint(s)
    check mem.rows.len == 3
    check mem.rows[0] == "foo"
    check mem.rows[1] == "bar"
    check mem.rows[2] == "baz"


suite "InlineScreen slice 7: capability split (single-writer structural)":

  test "positive witness: logSink.append is reachable":
    # Guards against vacuous pass: if this compiles, the enqueue door exists.
    let mem = newMemorySink()
    let s = newInlineScreen(mem, 5, 20)
    let ls = s.logSink
    check compiles(ls.append("x"))

  test "negative: logSink.takeBatch is NOT reachable (not on LogSink)":
    # takeBatch lives on ScrollbackLog (private) and on InlineScreen's
    # pipeline surface (logDrainBatch). It is NOT on LogSink.
    # A LogSink holder structurally cannot drain the buffer.
    let mem = newMemorySink()
    let s = newInlineScreen(mem, 5, 20)
    let ls = s.logSink
    check not compiles(ls.takeBatch(1))

  test "negative: logSink.log field is NOT reachable":
    # The log field on LogSink is not exported (no asterisk).
    # A LogSink holder cannot reach the underlying ScrollbackLog.
    let mem = newMemorySink()
    let s = newInlineScreen(mem, 5, 20)
    let ls = s.logSink
    check not compiles(ls.log)

  test "negative: logSink.logDrainBatch is NOT reachable":
    # logDrainBatch is on InlineScreen (the pipeline), not on LogSink.
    # This confirms the capability boundary: LogSink can only enqueue.
    let mem = newMemorySink()
    let s = newInlineScreen(mem, 5, 20)
    let ls = s.logSink
    check not compiles(ls.logDrainBatch(1))

  test "pipeline accessor logDrainBatch IS reachable on InlineScreen":
    # Positive witness: the pipeline (InlineScreen) CAN drain.
    let mem = newMemorySink()
    let s = newInlineScreen(mem, 5, 20)
    check compiles(s.logDrainBatch(1))


suite "InlineScreen slice 7: liveZoneHeight derivation":

  test "h=10, pinnedHeaderRows=1 → liveZoneHeight = 9":
    let mem = newMemorySink()
    let s = newInlineScreen(mem, 10, 40, pinnedHeaderRows = 1)
    check s.liveZoneHeight() == 9

  test "h=5, pinnedHeaderRows=3 → liveZoneHeight = 2":
    let mem = newMemorySink()
    let s = newInlineScreen(mem, 5, 40, pinnedHeaderRows = 3)
    check s.liveZoneHeight() == 2

  test "max(0,…) clamp: h=1, pinnedHeaderRows=1 → liveZoneHeight = 0":
    let mem = newMemorySink()
    let s = newInlineScreen(mem, 1, 40, pinnedHeaderRows = 1)
    check s.liveZoneHeight() == 0

  test "max(0,…) clamp: h < pinnedHeaderRows → liveZoneHeight = 0":
    let mem = newMemorySink()
    let s = newInlineScreen(mem, 2, 40, pinnedHeaderRows = 5)
    check s.liveZoneHeight() == 0

  test "liveZoneHeight reacts to size signal change":
    # Construct with a mutable signal; update it; assert liveZoneHeight
    # re-derives.
    let mem = newMemorySink()
    let sizeSig = signalC((10, 40))
    let s = newInlineScreen(mem, sizeSig, pinnedHeaderRows = 1)
    check s.liveZoneHeight() == 9
    sizeSig.set((20, 40))
    check s.liveZoneHeight() == 19


suite "InlineScreen slice 7: enqueue + buffer via LogSink":

  test "append through LogSink buffers one line":
    let mem = newMemorySink()
    let s = newInlineScreen(mem, 5, 20)
    let ls = s.logSink
    ls.append("hello")
    check s.logPendingLen() == 1

  test "multiple appends buffer in order":
    let mem = newMemorySink()
    let s = newInlineScreen(mem, 5, 20)
    let ls = s.logSink
    ls.append("line one")
    ls.append("line two")
    ls.append("line three")
    check s.logPendingLen() == 3

  test "logDrainBatch drains up to max lines and clears them":
    let mem = newMemorySink()
    let s = newInlineScreen(mem, 5, 20)
    let ls = s.logSink
    ls.append("a")
    ls.append("b")
    ls.append("c")
    let batch = s.logDrainBatch(2)
    check batch == @["a", "b"]
    check s.logPendingLen() == 1  # "c" remains

  test "logDrainBatch on empty screen returns empty seq":
    let mem = newMemorySink()
    let s = newInlineScreen(mem, 5, 20)
    let batch = s.logDrainBatch(10)
    check batch.len == 0
    check s.logPendingLen() == 0

  test "two LogSink handles from same screen share the underlying log":
    # logSink() wraps the same ScrollbackLog ref — appends through one
    # handle are visible via logPendingLen (same ref semantics).
    let mem = newMemorySink()
    let s = newInlineScreen(mem, 5, 20)
    let ls1 = s.logSink
    let ls2 = s.logSink
    ls1.append("from ls1")
    check s.logPendingLen() == 1
    ls2.append("from ls2")
    check s.logPendingLen() == 2

suite "InlineScreen slice 11 B: bindScrollback":

  test "B9 overflow routing: pushed items beyond liveZoneHeight spill to log":
    # liveZoneHeight = h - pinnedHeaderRows = 3 - 1 = 2
    let s = makeMemScreen11(3, 40)
    let c = collectionC[string]()
    bindScrollback(s.logSink, s.liveZoneHeight, c, proc(x: string): string = x)
    c.push("a")
    c.push("b")
    c.push("c")  # overflow: len=3, liveHeight=2 → 1 spilled ("a")
    c.push("d")  # overflow: len=4, liveHeight=2 → 2 spilled ("a","b")
    # "a" and "b" spilled; "c" and "d" in live window
    check s.logPendingLen() == 2
    let batch = s.logDrainBatch(10)
    check batch == @["a", "b"]

  test "B10 sanitization applies through bindScrollback":
    let s = makeMemScreen11(3, 40)
    let c = collectionC[string]()
    bindScrollback(s.logSink, s.liveZoneHeight, c, proc(x: string): string = x)
    c.push("x\ny")  # will overflow immediately (len=1, liveHeight=2: no overflow yet)
    c.push("z")     # len=2, liveHeight=2: still no overflow
    c.push("w")     # len=3, liveHeight=2: overflow=1, spill items[0]="x\ny" → sanitized "xy"
    check s.logPendingLen() == 1
    let batch = s.logDrainBatch(1)
    check batch == @["xy"]

  test "B11 no double-spill: newly-overflowed items only, never re-spills":
    let s = makeMemScreen11(3, 40)
    let c = collectionC[string]()
    bindScrollback(s.logSink, s.liveZoneHeight, c, proc(x: string): string = x)
    c.push("a")
    c.push("b")
    c.push("c")  # overflow=1, spill "a"
    check s.logPendingLen() == 1
    discard s.logDrainBatch(10)  # drain
    c.push("d")  # overflow=2, but committed=1; only "b" newly spilled
    check s.logPendingLen() == 1
    let batch = s.logDrainBatch(10)
    check batch == @["b"]  # not "a" again

  test "B12 structural capability: append compiles, takeBatch does not compile":
    let s = makeMemScreen11(5, 40)
    let sink = s.logSink
    check compiles(sink.append("x"))
    check not compiles(sink.takeBatch(1))
