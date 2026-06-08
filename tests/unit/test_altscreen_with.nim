## withAltScreen — exception-safe alternate-screen scope (slice 6a).
##
## Verifies the RAII-style `withAltScreen` template:
##
##   (a) exception path: ?1049l is emitted even when the body raises
##   (b) normal path: enter…body…leave in order, no double-leave
##   (c) exception still propagates — the template must not swallow it

import std/[posix, strutils, unittest]
import fresco/altscreen
import fresco/render/sink/terminal
import fresco/terminal/altscreen_cap
import fresco/terminal/ansi

# --- pipe helpers -------------------------------------------------------------

proc readAvailable(fd: cint): string =
  var buf: array[4096, char]
  result = ""
  while true:
    let n = posix.read(fd, addr buf[0], buf.len)
    if n <= 0: break
    for i in 0 ..< n:
      result.add buf[i]
    if n < buf.len: break

proc setNonblock(fd: cint) =
  let flags = fcntl(fd, F_GETFL, 0)
  discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)

type AltCapWitness = object
  altScreenGrant: AltScreenGrant

# =============================================================================

suite "withAltScreen: exception path emits ?1049l":

  test "body raises — leave is still emitted":
    var pipefds: array[2, cint]
    doAssert pipe(pipefds) == 0
    let rd = pipefds[0]
    let wr = pipefds[1]
    setNonblock(rd)
    defer:
      discard close(rd)
      discard close(wr)

    let sink = newTerminalSink(wr)
    var raised = false
    try:
      withAltScreen(sink, 3, 20, AltCapWitness(), s):
        raise newException(ValueError, "test error")
    except ValueError:
      raised = true
    check raised
    let bytes = readAvailable(rd)
    check altScreenEnter() in bytes
    check altScreenLeave() in bytes
    # ?1049l MUST appear AFTER ?1049h
    let enterPos = bytes.find(altScreenEnter())
    let leavePos = bytes.find(altScreenLeave())
    check enterPos >= 0
    check leavePos > enterPos

suite "withAltScreen: exception propagates":

  test "raised exception re-raises out of withAltScreen":
    var pipefds: array[2, cint]
    doAssert pipe(pipefds) == 0
    let rd = pipefds[0]
    let wr = pipefds[1]
    setNonblock(rd)
    defer:
      discard close(rd)
      discard close(wr)

    let sink = newTerminalSink(wr)
    var caught = false
    try:
      withAltScreen(sink, 2, 10, AltCapWitness(), s):
        raise newException(IOError, "propagate me")
    except IOError as e:
      caught = true
      check e.msg == "propagate me"
    check caught

suite "withAltScreen: normal path emits enter then leave, no double-leave":

  test "normal exit: ?1049h before content, ?1049l after content":
    var pipefds: array[2, cint]
    doAssert pipe(pipefds) == 0
    let rd = pipefds[0]
    let wr = pipefds[1]
    setNonblock(rd)
    defer:
      discard close(rd)
      discard close(wr)

    let sink = newTerminalSink(wr)
    withAltScreen(sink, 2, 20, AltCapWitness(), s):
      let r = newRegion(s, 0, 0, 2, 20)
      r.set(@["hello", "world"])
      s.paint()
    let bytes = readAvailable(rd)
    check altScreenEnter() in bytes
    check altScreenLeave() in bytes
    check "hello" in bytes
    # enter before content
    let enterPos = bytes.find(altScreenEnter())
    let helloPos = bytes.find("hello")
    check helloPos > enterPos
    # leave after content
    let leavePos = bytes.find(altScreenLeave())
    check leavePos > helloPos
    # exactly one leave sequence
    check bytes.count(altScreenLeave()) == 1
