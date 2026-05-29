## Stopwatch with lap history — F-M3 strict-clean canary.
##
## The compile-time-first / C-shape discipline applied to a realistic
## fresco app. Every reactive read is declared in a `[deps]` bracket;
## every source signal is baked via `signals:` or `collections:`. Compiles
## clean under `-d:intonacoStrict` — `nimble strictcheck` regression-tests
## this.
##
## Composition exercised:
##   * Multiple `signals:`-baked sources (running, elapsedMs)
##   * `collections:`-baked CollectionSignal (laps)
##   * `computed display, [elapsedMs]: ...` chains a derived signal off a
##     baked source; its height is composed and pragma-baked
##   * `mountWhen(running): spawn ...` — the decide/act seam (the increment
##     task is mounted while `running` is true, cancelled on toggle-off)
##   * `region` DSL with `row` / `rows` arms over the baked deps
##   * `bindCollection` over the baked CollectionSignal (lap history,
##     tail-windowed)
##
## Keys: [space] start/stop  [l] lap  [r] reset  [q] / Ctrl-C quit
##
## Run:
##   ./dev shell
##   nim r --hints:off --path:src examples/ex05_stopwatch.nim
##
## Companion test: tests/integration/test_ex05_stopwatch.nim (headless).

{.experimental: "callOperator".}

import std/[strformat, unicode]
import chronos
import fresco
import fresco/terminal/termios

proc formatElapsed(ms: int): string =
  let totalSecs = ms div 1000
  let mm = totalSecs div 60
  let ss = totalSecs mod 60
  let cs = (ms mod 1000) div 10           # centiseconds
  fmt"{mm:02}:{ss:02}.{cs:02}"

# A counter we can read from outside the app (for the headless test
# assertions). Kept module-scope so the test can inspect it after the
# app loop returns.
var tickCount* = 0

proc runStopwatch*(stream: InputStream, screen: Screen)
                  {.async: (raises: [Exception]).} =
  let root = newScope()
  try:
    withScope(root):
      signals:
        running   = false
        elapsedMs = 0

      collections:
        laps = newSeq[int]()

      # Derive the display string from the elapsed counter. Height-baked
      # at compile time: elapsedMs has height 0 → display has height 1.
      computed display, [elapsedMs]:
        formatElapsed(elapsedMs)

      # The increment task. Mounted while `running` is true; cancelled on
      # toggle-off via mountWhen's decide/act seam.
      proc tickLoop() {.async: (raises: [Exception]).} =
        while true:
          await sleepAsync(10.milliseconds)
          elapsedMs := elapsedMs.peek() + 10
          inc tickCount

      mountWhen(running):
        spawn tickLoop()

      let panel = newRegion(screen, 0, 0, screen.height, screen.width)
      region(panel):
        row 0, []:           "fresco stopwatch — [space] start/stop  [l] lap  [r] reset  [q] quit"
        row 1, [display]:    "elapsed: " & display
        row 2, [running]:    (if running: "[ RUNNING ]" else: "[ stopped ]")
        row 3, []:           "laps:"
        rows 4..^1, []:      laps

      let painter = runAutoPaint(screen)
      defer: painter.cancelSoon()

      while true:
        receive:
          on stream as ev:
            Char(' '): running := not running.peek()
            Char('l'): laps.push(elapsedMs.peek())
            Char('r'):
              elapsedMs := 0
              laps.clear()
            Char('q'): return
            Ctrl('c'): return
            _: discard
  finally:
    dispose(root)

when isMainModule:
  proc main() {.async: (raises: [Exception]).} =
    withCbreak:
      stderr.write altScreenEnter()
      defer:
        stderr.write altScreenLeave()
        stderr.flushFile()

      let stream = newInputStream(cint(0))
      start(stream)
      defer: stop(stream)

      let screen = newScreen()
      await runStopwatch(stream, screen)

  waitFor main()
