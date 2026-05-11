## Integration test: drive the review widget through a PTY.

import std/unittest
import std/[posix, termios]
import chronos
import fresco/input as fresco_input
import fresco/screen
import fresco/widgets/review

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

proc drive(stream: InputStream, screen: Screen, master: cint,
           keys: string): Future[ReviewOutcome]
           {.async: (raises: [Exception]).} =
  proc feeder() {.async: (raises: [Exception]).} =
    await sleepAsync(20.milliseconds)
    writeAll(master, keys)
  asyncSpawn feeder()
  return await review(stream, screen,
    top = 0, left = 0, height = 20, width = 60,
    prompt = "review these changes",
    oldText = "line one\nline two\nline three\n",
    newText = "line one\nline 2\nline three\n")

proc runReview(keys: string): ReviewOutcome =
  let (master, slave) = openPtyPair()
  let stream = newInputStream(slave)
  fresco_input.start(stream)
  let screen = newScreen(24, 80, slave)
  try:
    result = waitFor drive(stream, screen, master, keys)
  finally:
    fresco_input.stop(stream)
    discard close(master)
    discard close(slave)

suite "review widget over PTY":

  test "Enter on first option approves":
    let o = runReview("\r")
    check o.kind == rkApprove

  test "ArrowDown then Enter rejects":
    let o = runReview("\x1b[B\r")
    check o.kind == rkReject

  test "two ArrowDowns + Enter + typed feedback returns rkEditFeedback":
    let o = runReview("\x1b[B\x1b[B\r" & "needs more context" & "\r")
    check o.kind == rkEditFeedback
    check o.feedback == "needs more context"

  test "Ctrl-C from the select cancels":
    let o = runReview("\x03")
    check o.kind == rkCancelled
