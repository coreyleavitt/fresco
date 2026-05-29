## Devtools panel headless test (Screen v2 Phase 2 — closes #99 / #101).
##
## Exercises `runDevtoolsPanel` directly under a `MemoryScreen` (=
## `Screen[MemorySink]`). The generic version dispatches paint through
## the Sink concept; no terminal, no PTY, no callback shimming.

import std/[unittest, strutils, unicode]
import chronos
import fresco/headless/input
import fresco/events as keyevents
import fresco/screen
import fresco/devtools/panel
import intonaco/journal/events
import intonaco/journal/log
import intonaco/task/supervisor
import fresco/render/sink/memory

suite "devtools panel: headless via MemoryScreen":

  test "panel renders widgets into MemorySink and exits on 'q'":
    proc inner(): Future[void] {.async: (raises: [Exception]).} =
      let stream = newSyntheticInputStream()
      defer: stream.stop()

      let j = newJournal()
      let t = TaskId.fresh()
      discard j.logTaskSpawned(t, NoEvent, "demo", "")
      discard j.logSignalWrite(t, NoEvent, "x", "1")
      discard j.logSignalWrite(t, NoEvent, "x", "2")

      let sup = newSupervisor()
      let screen = newScreen(newMemorySink(), 12, 60)

      proc feeder() {.async: (raises: [Exception]).} =
        await sleepAsync(20.milliseconds)
        stream.pushKey(KeyEvent(kind: kChar, rune: "q".runeAt(0)))

      asyncSpawn feeder()
      await runDevtoolsPanel(j, @[sup], stream, screen)

      check screen.regions.len == 3
      var sawSignalWrite = false
      for line in screen.sink.rows:
        if "write x=2" in line: sawSignalWrite = true
      check sawSignalWrite

    waitFor inner()

  test "scrubber row updates after ArrowLeft (latent reactivity bug — F-M2)":
    ## RED for #106: the bindRow scrubR body must re-run on cursor
    ## change. Before F-M2 the panel's scrubber state is plain int/bool
    ## fields the input loop mutates in-place — bindRow has no deps, so
    ## the rendered row stays frozen at its initial value despite the
    ## state change. After F-M2 the scrubber state is a Signal, the
    ## bindRow declares it as a dep, and the row reflects each ←/→.
    proc inner(): Future[void] {.async: (raises: [Exception]).} =
      let stream = newSyntheticInputStream()
      defer: stream.stop()

      let j = newJournal()
      let t = TaskId.fresh()
      discard j.logTaskSpawned(t, NoEvent, "demo", "")
      discard j.logSignalWrite(t, NoEvent, "x", "1")
      discard j.logSignalWrite(t, NoEvent, "x", "2")
      # 3 events total → initial scrubber cursor at index 2 (last).
      # First ← engages scrub mode AND decrements: cursor: 2 → 1.

      let sup = newSupervisor()
      let screen = newScreen(newMemorySink(), 12, 60)

      proc feeder() {.async: (raises: [Exception]).} =
        await sleepAsync(20.milliseconds)
        stream.pushKey(atomKey(kArrowLeft))
        await sleepAsync(20.milliseconds)
        stream.pushKey(KeyEvent(kind: kChar, rune: "q".runeAt(0)))

      asyncSpawn feeder()
      await runDevtoolsPanel(j, @[sup], stream, screen)

      # The scrubber row should reflect `1/3`. Pre-F-M2 it stays `2/3`.
      var sawCursor1 = false
      for line in screen.sink.rows:
        if "1/3" in line: sawCursor1 = true
      check sawCursor1

    waitFor inner()
