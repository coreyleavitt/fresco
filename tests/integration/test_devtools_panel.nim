## End-to-end devtools panel smoke test (#36).
##
## PTY-driven integration: spawn the panel, feed keys, verify it
## binds the widgets and exits cleanly on 'q'.

import std/unittest
import std/[posix, strutils, unicode]
import chronos
import fresco/input as fresco_input
import fresco/events as keyevents
import fresco/devtools/panel
import fresco/devtools/widgets
import intonaco/journal/events
import intonaco/journal/log
import intonaco/task/supervisor
import fresco/screen

proc posix_openpt(flags: cint): cint {.importc, header: "<stdlib.h>".}
proc grantpt(fd: cint): cint           {.importc, header: "<stdlib.h>".}
proc unlockpt(fd: cint): cint          {.importc, header: "<stdlib.h>".}
proc ptsname(fd: cint): cstring        {.importc, header: "<stdlib.h>".}

proc openPtyPair(): tuple[master, slave: cint] =
  let master = posix_openpt(O_RDWR or O_NOCTTY)
  doAssert master >= 0
  doAssert grantpt(master) == 0
  doAssert unlockpt(master) == 0
  let slave = open(ptsname(master), O_RDWR or O_NOCTTY)
  doAssert slave >= 0
  return (master, slave)

proc writeAll(fd: cint, s: string) =
  if s.len == 0: return
  let n = posix.write(fd, unsafeAddr s[0], s.len)
  doAssert n == s.len

suite "devtools panel: end-to-end smoke (PTY)":

  test "panel binds widgets, renders, exits on 'q'":
    proc inner(): Future[void] {.async: (raises: [Exception]).} =
      let (master, slave) = openPtyPair()
      let stream = newInputStream(slave)
      fresco_input.start(stream)
      defer:
        fresco_input.stop(stream)
        discard close(master)
        discard close(slave)

      # Seed a journal with a few events so the stream + scrubber
      # have something to render.
      let j = newJournal()
      let t = TaskId.fresh()
      discard j.logTaskSpawned(t, NoEvent, "demo", "")
      discard j.logSignalWrite(t, NoEvent, "x", "1")
      discard j.logSignalWrite(t, NoEvent, "x", "2")

      let sup = newSupervisor()
      let screen = newScreen(12, 60)    # synthetic dimensions

      proc feeder() {.async: (raises: [Exception]).} =
        await sleepAsync(40.milliseconds)
        writeAll(master, "q")

      asyncSpawn feeder()
      await runDevtoolsPanel(j, @[sup], stream, screen)

      # If we get here, the panel returned (q was received). Verify
      # the widget regions got populated (i.e., bindings ran).
      check screen.regions.len == 3
      # Stream region (middle third) should contain the last journal
      # events rendered via the widget.
      let streamR = screen.regions[1]
      var sawSignalWrite = false
      for line in streamR.target:
        if "write x=2" in line: sawSignalWrite = true
      check sawSignalWrite

    waitFor inner()
