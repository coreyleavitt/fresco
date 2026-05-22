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
