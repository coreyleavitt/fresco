## Reactive counter — the smallest end-to-end fresco program.
##
## Pass: a single line in the top-left of the terminal shows
## "count: N". Each `+`/`-` press updates it. `q` or `Ctrl-C` exits
## with the terminal restored. Demonstrates the full stack:
##
##   raw input → KeyEvent → `receive` arm → Signal write → reactive
##   binding fires → Region target buffer mutated → paint emits ANSI
##
## Run:
##
##   ./dev shell
##   # inside:
##   nim r --hints:off --path:src examples/ex02_counter.nim

{.experimental: "callOperator".}

import chronos
import fresco
import fresco/terminal/termios

proc app(stream: InputStream, screen: Screen)
        {.async: (raises: [Exception]).} =
  let root = newScope()
  try:
    withScope(root):
      signals:
        count = 0

      let panel = newRegion(screen, 0, 0, 2, screen.width)
      region(panel):
        row 0: "fresco counter — press + / -, q or Ctrl-C to quit"
        row 1: "count: " & $count()
      paint(screen)

      while true:
        receive:
          on stream as ev:
            Char('+'):
              count := count() + 1
              paint(screen)
            Char('-'):
              count := count() - 1
              paint(screen)
            Char('q'): return
            Ctrl('c'): return
            _: discard
  finally:
    dispose(root)

proc main() {.async: (raises: [Exception]).} =
  withCbreak:
    # Enter the alt screen so we don't clobber the user's scrollback,
    # leave on exit (withCbreak's signal handlers also restore on
    # SIGINT/SIGTERM/SIGSEGV — try the demo, then Ctrl-C and confirm
    # your prompt comes back unscathed).
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
