## Animation demo — tween vs spring side-by-side.
##
## Two horizontal bars share a target value. The top bar uses `tween`
## with linear easing; the bottom uses `spring` with default
## (near-critical) parameters; an optional third uses underdamped
## spring (visible overshoot).
##
## Keys: digits 1..9 set target to N/9 of the bar width.
##       0 sets target to 0.
##       q or Ctrl-C quits.
##
## Run:
##   ./dev shell
##   nim r -d:release --hints:off --path:src examples/ex04_animation.nim

{.experimental: "callOperator".}

import std/[strutils, unicode]
import chronos
import fresco
import fresco/terminal/termios

const BarWidth = 40
const Filled   = "█"   # █ (full block, multi-byte UTF-8)

proc bar(value: float): string =
  let v = clamp(value, 0.0, 1.0)
  let filled = int(v * BarWidth.float)
  result = ""
  for i in 0 ..< filled: result.add Filled
  for i in filled ..< BarWidth: result.add ' '
  result.add " " & formatFloat(v, ffDecimal, 3)

proc app(stream: InputStream, screen: Screen)
        {.async: (raises: [Exception]).} =
  let root = newScope()
  try:
    withScope(root):
      signals:
        tweenVal      = 0.0
        springVal     = 0.0
        bouncyVal     = 0.0
        target        = 0.0

      let panel = newRegion(screen, 0, 0, 8, screen.width)
      region(panel):
        row 0: "fresco animation demo — 0-9 = set target, q / Ctrl-C = quit"
        row 1: "target:  " & formatFloat(target(), ffDecimal, 3)
        row 2: ""
        row 3: "tween    [linear, 600ms] " & bar(tweenVal())
        row 4: "spring   [k=170, c=26]   " & bar(springVal())
        row 5: "bouncy   [k=200, c=8]    " & bar(bouncyVal())
        row 6: ""
        row 7: "watch the bouncy spring overshoot and settle"

      # Re-paint on every signal change. Without this createEffect the
      # bindings update target buffers but the renderer never flushes.
      createEffect proc() =
        discard tweenVal()
        discard springVal()
        discard bouncyVal()
        discard target()
        paint(screen)

      while true:
        receive stream:
          Char('q'): return
          Ctrl('c'): return
          Char(c):
            # `c` is a `Rune`; stringify and check single-byte digit.
            let s = $c
            if s.len == 1 and s[0] in '0'..'9':
              let n = ord(s[0]) - ord('0')
              let t = n.float / 9.0
              target := t
              discard tween(tweenVal, t, 600.milliseconds, esOutCubic)
              discard spring(springVal, t)
              discard spring(bouncyVal, t, stiffness = 200.0, damping = 8.0)
          _: discard
  finally:
    dispose(root)

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
    await app(stream, screen)

waitFor main()
