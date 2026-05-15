## Devtools panel (#36) — live introspection UI built using fresco.
##
##   ./dev shell
##   nim r --hints:off --path:src examples/ex03_devtools.nim
##
## Three vertical regions:
##   - Top third:    supervisor task tree (live)
##   - Middle third: tail-window journal stream (last N events)
##   - Bottom third: time-warp scrubber
##
## Hotkeys:
##   q              quit
##   ← / →          step the scrubber; rewindTo each cursor position
##   Escape         resumeLive (return to head state)
##   Enter          pin the cursor's event for causal inspection
##
## The host demo spawns a couple of background workers that mutate
## signals; you can scrub through their history and watch the
## reactive state revert / replay.

{.experimental: "callOperator".}

import chronos
import fresco
import fresco/terminal/termios
import fresco/devtools/panel
import fresco/reactive/signal

proc demoWorker(id: int) {.async.} =
  signals:
    count = 0
  for i in 1 .. 20:
    count := id * 1000 + i
    await sleepAsync(120.milliseconds)

proc main() {.async: (raises: [Exception]).} =
  globalJournal = newJournal()
  let sup = newSupervisor()
  sup.addChild("workerA", lcTemporary,
               proc(): Future[void] {.async.} = await demoWorker(1))
  sup.addChild("workerB", lcTemporary,
               proc(): Future[void] {.async.} = await demoWorker(2))
  let supRun = spawn sup.run()

  withCbreak:
    stderr.write altScreenEnter()
    defer:
      stderr.write altScreenLeave()
      stderr.flushFile()

    let stream = newInputStream(cint(0))
    start(stream)
    defer: stop(stream)

    let screen = newScreen()
    await runDevtoolsPanel(globalJournal, @[sup], stream, screen)

  # Panel exited via 'q'. Wait for workers to finish so the demo
  # ends cleanly rather than killing tasks mid-flight.
  await supRun.future

waitFor main()
