## Journal integration: input + supervisor hooks.

import std/[unittest, strutils]
import std/[posix, termios]
import chronos
import fresco/events
import intonaco/journal/events as jev
import intonaco/journal/log
import fresco/input as fresco_input
import intonaco/reactive/scope
import intonaco/task/core
import intonaco/task/supervisor
import fresco/hotkey

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

proc tick(): Future[void] {.async: (raises: [CancelledError]).} =
  await sleepAsync(0.milliseconds)

suite "journal: input":

  setup:
    globalJournal = newJournal()

  teardown:
    resetJournal()

  test "nextKey writes ekKeyReceived":
    proc body() {.async: (raises: [Exception]).} =
      let (master, slave) = openPtyPair()
      let stream = newInputStream(slave)
      fresco_input.start(stream)
      defer:
        fresco_input.stop(stream)
        discard close(master); discard close(slave)
      proc reader() {.async.} =
        writeAll(master, "x")
        let _ = await stream.nextKey()
      let m = spawn reader()
      await m.wait()
      let received = globalJournal.byKind(ekKeyReceived)
      check received.len == 1
      check "Char(x)" in received[0].keySummary
    waitFor body()

  test "hotkey writes ekKeyConsumed":
    proc body() {.async: (raises: [Exception]).} =
      let (master, slave) = openPtyPair()
      let stream = newInputStream(slave)
      fresco_input.start(stream)
      defer:
        fresco_input.stop(stream)
        discard close(master); discard close(slave)
      let sc = newScope()
      withScope(sc):
        hotkey stream, ctrlKey('q'):
          discard
      writeAll(master, "\x11")
      await sleepAsync(30.milliseconds)
      let consumed = globalJournal.byKind(ekKeyConsumed)
      check consumed.len == 1
      check "Ctrl-q" in consumed[0].keySummary
      dispose(sc)
    waitFor body()

  test "hotkey-consumed events attribute to the registering scope's task":
    proc body() {.async: (raises: [Exception]).} =
      let (master, slave) = openPtyPair()
      let stream = newInputStream(slave)
      fresco_input.start(stream)
      defer:
        fresco_input.stop(stream)
        discard close(master); discard close(slave)

      let sc = newScope()
      sc.taskId = TaskId.fresh()
      let owningTid = sc.taskId
      withScope(sc):
        hotkey stream, ctrlKey('q'):
          discard

      writeAll(master, "\x11")
      await sleepAsync(30.milliseconds)
      let consumed = globalJournal.byKind(ekKeyConsumed)
      check consumed.len == 1
      check consumed[0].taskId == owningTid     # not whatever's current at fire
      dispose(sc)
    waitFor body()

suite "journal: supervisor":

  setup:
    globalJournal = newJournal()

  teardown:
    resetJournal()

  test "permanent restart writes ekSupervisorRestart":
    proc body() {.async: (raises: [Exception]).} =
      var attempts = 0
      proc child(): Future[void] {.async.} =
        inc attempts
        await sleepAsync(2.milliseconds)
      let sup = newSupervisor(maxRestarts = 10, within = 1.seconds)
      sup.addChild("worker", lcPermanent, child)
      let m = spawn sup.run()
      await sleepAsync(30.milliseconds)
      m.cancel()
      let restarts = globalJournal.byKind(ekSupervisorRestart)
      check restarts.len >= 2
      check restarts[0].restartName == "worker"
    waitFor body()

  test "rate-limit exhaustion writes ekSupervisorEscalate":
    proc body() {.async: (raises: [Exception]).} =
      proc flap(): Future[void] {.async.} =
        await sleepAsync(1.milliseconds)
        raise newException(ValueError, "boom")
      let sup = newSupervisor(maxRestarts = 2, within = 1.seconds)
      sup.addChild("flap", lcPermanent, flap)
      try: await sup.run()
      except SupervisorEscalation: discard
      let escalations = globalJournal.byKind(ekSupervisorEscalate)
      check escalations.len == 1
      check escalations[0].escalateName == "flap"
    waitFor body()

  test "temporary terminate writes ekSupervisorTerminate":
    proc body() {.async: (raises: [Exception]).} =
      proc oneShot(): Future[void] {.async.} =
        await sleepAsync(2.milliseconds)
      let sup = newSupervisor()
      sup.addChild("one", lcTemporary, oneShot)
      await sup.run()
      let terms = globalJournal.byKind(ekSupervisorTerminate)
      check terms.len == 1
      check terms[0].terminateName == "one"
    waitFor body()
