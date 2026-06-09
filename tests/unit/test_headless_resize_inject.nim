## test_headless_resize_inject.nim — S0b: resize-injection seam in runHeadless
## InlineScreen overload.
##
## RED → GREEN cycle for RFC-0011 S0b.
##
## Proves that the headless harness can inject scripted terminal-resize events
## mid-run via a unified InlineEvent stream (Key | Resize), each applied via
## s.setSize(h, w) with one dispatcher turn to settle reactive updates before
## the next event. After settlement, s.liveZoneHeight() and s.layout.{height,
## width} must reflect the new dimensions.
##
## Tests:
##   1. InlineEvent type exists: Key and Resize variants compile.
##   2. Resize event mid-run updates liveZoneHeight before next Key is processed.
##   3. layout dimensions reflect the new size after resize event settles.
##   4. rows and committedRows are still captured correctly across a resize.
##   5. Existing @[] call site compiles unchanged (backward compat).

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
# Suite 1: InlineEvent type
# ---------------------------------------------------------------------------

suite "S0b: InlineEvent type":

  test "InlineEvent Key and Resize variants compile":
    ## The type must exist and both variants must be constructible.
    let ev1 = InlineEvent(kind: ievKey, key: atomKey(kEnter))
    let ev2 = InlineEvent(kind: ievResize, resizeH: 30, resizeW: 100)
    check ev1.kind == ievKey
    check ev2.kind == ievResize
    check ev2.resizeH == 30
    check ev2.resizeW == 100

  test "keyEv and resizeEv convenience constructors":
    let k = keyEv(atomKey(kEscape))
    let r = resizeEv(20, 60)
    check k.kind == ievKey
    check r.resizeH == 20

# ---------------------------------------------------------------------------
# Suite 2: resize injection via runHeadless InlineScreen overload
# ---------------------------------------------------------------------------

suite "S0b: resize injection via runHeadless":

  test "resize event updates liveZoneHeight mid-run":
    ## App observes liveZoneHeight at two points: before and after the resize
    ## event. Before: 24 - 1 = 23. After resize to 30 rows: 30 - 1 = 29.
    ##
    ## No region is allocated — the test targets only the reactive scalar.
    ## The app awaits a key as a sync point: the harness delivers it after
    ## the resize + one perKeySettle turn, so liveZoneHeight has settled.
    proc body() {.async: (raises: [Exception]).} =
      let sink = newMemorySink()
      let s = newInlineScreen(sink, 24, 80)
      # No region: we're only testing liveZoneHeight reactivity.

      var heightBefore = 0
      var heightAfter = 0

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        heightBefore = s.liveZoneHeight()
        # Wait for the key delivered after the resize + settle.
        let key = await stream.nextKey()
        heightAfter = s.liveZoneHeight()
        discard key

      # Script: resize to 30 rows (settle), then send a key so the app reads
      # heightAfter after liveZoneHeight has reacted.
      let events = @[
        resizeEv(30, 80),
        keyEv(atomKey(kEscape)),
      ]
      discard await runHeadless(s, app, events = events)

      check heightBefore == 23
      check heightAfter == 29  # 30 - 1

    waitFor body()

  test "layout dimensions reflect new size after resize event":
    ## After a resize event, s.layout.height and s.layout.width must equal
    ## the new dimensions.
    proc body() {.async: (raises: [Exception]).} =
      let sink = newMemorySink()
      let s = newInlineScreen(sink, 24, 80)

      var layoutHAfter = 0
      var layoutWAfter = 0

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        let key = await stream.nextKey()
        layoutHAfter = s.layout.height
        layoutWAfter = s.layout.width
        discard key

      let events = @[
        resizeEv(30, 120),
        keyEv(atomKey(kEscape)),
      ]
      discard await runHeadless(s, app, events = events)

      check layoutHAfter == 30
      check layoutWAfter == 120

    waitFor body()

  test "committedRows from pre-resize commit preserved; layout height updated":
    ## Lines committed (via s.commit()) BEFORE the resize event appear in
    ## HeadlessResult.committedRows. After the resize the layout height is
    ## 15, so result.rows (the MemorySink live-band snapshot) has 15 entries.
    ##
    ## Post-resize appendLine (without s.commit()) is deferred to a future
    ## test once S0c's relayout helper keeps the region bottom-anchored.
    proc body() {.async: (raises: [Exception]).} =
      let sink = newMemorySink()
      # Start at 10 rows, pinnedHeaderRows=1, liveZoneHeight=9.
      # Region at row 1, height 9: lowestEdge = 10 = layout.height ✓
      let s = newInlineScreen(sink, 10, 40)
      let r = s.newRegion(1, 0, 9, 40)

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        r.set(["initial live"])
        s.appendLine("before resize")
        discard s.commit()
        # Await the key delivered after the resize event.
        let key = await stream.nextKey()
        discard key
        # Do NOT appendLine or commit here: after resize the region is no
        # longer bottom-anchored (lowestEdge=10 < new height=15), so the
        # async commit driver would raise BandNotBottomAnchoredDefect.
        # Post-resize log capture is tested after S0c adds the relayout helper.

      let events = @[
        resizeEv(15, 40),
        keyEv(atomKey(kEscape)),
      ]
      let result = await runHeadless(s, app, events = events)

      check result.committedRows.contains("before resize")
      # paint() captures the layout at its new height.
      check result.rows.len == 15

    waitFor body()

  test "empty events seq still works (backward compat)":
    ## Existing call sites that pass events = @[] must continue to compile
    ## and behave as before: app runs, drain is final, committedRows captured.
    proc body() {.async: (raises: [Exception]).} =
      let sink = newMemorySink()
      let s = newInlineScreen(sink, 10, 40)
      let r = s.newRegion(1, 0, 9, 40)

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        r.set(["hello"])
        s.appendLine("line1")
        discard s.commit()

      let result = await runHeadless(s, app, events = @[])
      check result.committedRows.len == 1
      check result.committedRows[0] == "line1"
      check result.rows[1] == "hello"

    waitFor body()

  test "Key events in unified stream still drive the app":
    ## Pure key-only InlineEvent stream behaves identically to the old
    ## seq[KeyEvent] path: the app receives the keys and can act on them.
    proc body() {.async: (raises: [Exception]).} =
      let sink = newMemorySink()
      let s = newInlineScreen(sink, 10, 40)
      let r = s.newRegion(1, 0, 9, 40)

      var sawKey = false

      proc app(stream: InputStream) {.async: (raises: [Exception]).} =
        let key = await stream.nextKey()
        if key.kind == kEscape:
          sawKey = true

      let events = @[keyEv(atomKey(kEscape))]
      discard await runHeadless(s, app, events = events)

      check sawKey

    waitFor body()
