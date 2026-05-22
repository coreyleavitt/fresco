## runHeadless test harness (Split Phase 2).
##
## End-to-end: an app proc binds to a layout, awaits keys on a stream,
## responds reactively. runHeadless wires Layout + MemorySink +
## SyntheticInputStream, feeds inputs, captures the final composed
## rows. The high-level convenience for headless / CI testing.

import std/unicode
import std/unittest
import chronos
import fresco/events
import fresco/input
import intonaco/reactive/scope
import intonaco/reactive/signal
import fresco/reactive/binding
import fresco/render/layout
import fresco/headless/input as headless_input
import fresco/headless/runner

suite "runHeadless: end-to-end test harness":

  test "an app receives input + binds; runHeadless captures final rendered rows":
    proc app(stream: InputStream, layout: Layout) {.async: (raises: [Exception]).} =
      let root = newScope()
      defer: dispose(root)
      withScope(root):
        let count = signal(0)
        let region = newRegion(layout, 0, 0, 2, 20)
        bindRow region, 0: "count: " & $count()
        bindRow region, 1: "ready"
        while true:
          let key = await stream.nextKey()
          if key.kind == kChar:
            case $key.rune
            of " ": count.set(count() + 1)
            of "q": return
            else: discard

    proc body() {.async: (raises: [Exception]).} =
      let result = await runHeadless(app,
                                     inputs = @[charKey(Rune(' ')),
                                                charKey(Rune(' ')),
                                                charKey(Rune(' ')),
                                                charKey(Rune('q'))],
                                     height = 2, width = 20)
      check result.rows[0] == "count: 3"
      check result.rows[1] == "ready"
    waitFor body()
