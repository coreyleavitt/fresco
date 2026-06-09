## Full-screen clock demo — AltScreen surface type.
##
## Demonstrates the AltScreen ownership lifecycle:
##   acquireAltScreenGrant → withAltScreen → enter (?1049h) → regions →
##   auto-paint reactive updates → leave (?1049l) on exit.
##
## Unlike the existing ex02/ex04/ex05 examples (which use the raw
## `altScreenEnter()`/`altScreenLeave()` escape strings directly), this
## example uses the AltScreen surface API: `newAltScreen` + `enter` /
## `leave` via the `withAltScreen` exception-safe template, paired with
## `acquireAltScreenGrant` to obtain the compile-time capability witness.
##
## Keys: q or Ctrl-C quit — the alt-screen is restored (your original
## scrollback reappears) on every exit path including crashes, because
## `withAltScreen`'s `finally` always calls `leave()` and `withCbreak`'s
## signal handlers fire on SIGINT/SIGTERM/SIGSEGV.
##
## Visual check: your shell scrollback disappears when the app starts
## (?1049h switches to the alt buffer) and is fully restored when it exits
## (?1049l switches back). The UI — title + elapsed counter + footer —
## is confined to the alt screen and never bleeds into scrollback history.
##
## Run:
##   ./dev shell
##   nim r --hints:off --path:src examples/altscreen_app.nim

{.experimental: "callOperator".}

import std/[strformat, unicode]
import chronos
import fresco
import fresco/altscreen
import fresco/render/sink/terminal
import fresco/terminal/altscreen_cap
import fresco/terminal/termios

proc formatElapsed(ms: int): string =
  let totalSecs = ms div 1000
  let mm        = totalSecs div 60
  let ss        = totalSecs mod 60
  let cs        = (ms mod 1000) div 10
  fmt"{mm:02}:{ss:02}.{cs:02}"

proc app(stream: InputStream, screen: AltScreen[TerminalSink])
        {.async: (raises: [Exception]).} =
  let root = newScope()
  try:
    withScope(root):
      signals:
        elapsedMs = 0

      computed display, [elapsedMs]:
        formatElapsed(elapsedMs)

      # Three regions: title (row 0), body (rows 1..h-2), footer (last row).
      let h = screen.height
      let w = screen.width
      let title  = newRegion(screen, 0,   0, 1,      w)
      let body   = newRegion(screen, 1,   0, h - 2,  w)
      let footer = newRegion(screen, h-1, 0, 1,      w)

      region(title):
        row 0, []: "fresco AltScreen demo — full-screen clock"

      region(body):
        row 0, [display]: "elapsed: " & display
        row 1, []:        ""
        row 2, []:        "The alt-screen buffer owns this frame."
        row 3, []:        "Your shell scrollback is hidden (not destroyed)."

      region(footer):
        row 0, []: "[q] or [Ctrl-C] to quit"

      # Tick + paint task: update elapsedMs every 10 ms, then repaint.
      # AltScreen has no runAutoPaint (it's a screen.nim / inline_screen.nim
      # primitive); we drive paint explicitly inside the tick loop.
      proc tickLoop() {.async: (raises: [Exception]).} =
        while true:
          await sleepAsync(10.milliseconds)
          elapsedMs := elapsedMs.peek() + 10
          screen.paint()

      let ticker = spawn tickLoop()
      defer: ticker.cancel()

      while true:
        receive:
          on stream as ev:
            Char('q'): return
            Ctrl('c'): return
            _: discard
  finally:
    dispose(root)

proc main() {.async: (raises: [Exception]).} =
  withCbreak:
    let sink = newTerminalSink()   # defaults to STDERR_FILENO
    let cap  = acquireAltScreenGrant(true)
    withAltScreen(sink, 24, 80, cap, s):
      let stream = newInputStream(cint(0))
      start(stream)
      defer: stop(stream)
      await app(stream, s)

waitFor main()
