## Devtools panel headless test (Screen v2 issue #101 stopgap).
##
## Exercises `runDevtoolsPanel` via the layout+commit-callback overload
## under a `MemorySink`. Validates that the panel composes its widgets
## and renders without a real terminal or PTY.

import std/[unittest, strutils, unicode]
import chronos
import fresco/headless/input
import fresco/events as keyevents
import fresco/devtools/panel
import fresco/journal/events
import fresco/journal/log
import fresco/task/supervisor
import fresco/render/layout
import fresco/render/sink/memory

suite "devtools panel: headless via MemorySink + commit-callback":

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
      let layout = newLayout(12, 60)
      let memSink = newMemorySink()

      proc feeder() {.async: (raises: [Exception]).} =
        await sleepAsync(20.milliseconds)
        stream.pushKey(KeyEvent(kind: kChar, rune: "q".runeAt(0)))

      asyncSpawn feeder()
      await runDevtoolsPanel(j, @[sup], stream, layout,
                             proc(l: Layout) = memSink.commit(l))

      check layout.regions.len == 3
      # Stream region (middle third) should contain the rendered events.
      var sawSignalWrite = false
      for line in memSink.rows:
        if "write x=2" in line: sawSignalWrite = true
      check sawSignalWrite

    waitFor inner()
