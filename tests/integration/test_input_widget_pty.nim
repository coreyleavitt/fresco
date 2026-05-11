## Integration test: drive the input-line widget through a PTY pair.

import std/unittest
import std/[posix, termios]
import chronos
import fresco/input as fresco_input
import fresco/events
import fresco/screen
import fresco/widgets/input as inputw

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

proc drive(stream: InputStream, screen: Screen, region: Region,
           master: cint, keys: string, initial = "", history: History = nil
          ): Future[InputOutcome] {.async: (raises: [Exception]).} =
  proc feeder() {.async: (raises: [Exception]).} =
    await sleepAsync(20.milliseconds)
    writeAll(master, keys)
  asyncSpawn feeder()
  return await inputLine(stream, screen, region,
                         prompt = "> ", initial = initial,
                         history = history)

proc runInput(keys: string, initial = "", history: History = nil): InputOutcome =
  let (master, slave) = openPtyPair()
  let stream = newInputStream(slave)
  fresco_input.start(stream)
  let screen = newScreen(5, 80, slave)
  let region = newRegion(screen, 0, 0, 1, 80)
  try:
    result = waitFor drive(stream, screen, region, master, keys, initial, history)
  finally:
    fresco_input.stop(stream)
    discard close(master)
    discard close(slave)

suite "input widget over PTY":

  test "type 'hello' + Enter submits 'hello'":
    let o = runInput("hello\r")
    check o.kind == ioSubmitted
    check o.text == "hello"

  test "backspace removes the last char":
    let o = runInput("abc\x08\r")
    check o.kind == ioSubmitted
    check o.text == "ab"

  test "left arrow + insert mid-string":
    let o = runInput("ace\x1b[D" & "b" & "\r", initial = "")
    # Type a, c, e -> "ace" cursor=3
    # ESC [ D = ArrowLeft -> cursor=2 (between 'c' and 'e')
    # Type 'b' -> "acbe" cursor=3
    check o.text == "acbe"

  test "Home moves cursor to 0; typed char prepends":
    let o = runInput("xyz\x1b[H" & "0" & "\r")
    check o.text == "0xyz"

  test "Ctrl-U clears the line":
    let o = runInput("hello\x15\r")
    check o.text == ""

  test "Ctrl-W deletes the last word":
    let o = runInput("hello world\x17\r")
    check o.text == "hello "

  test "Ctrl-W on trailing whitespace skips whitespace then deletes word":
    let o = runInput("foo bar  \x17\r")
    check o.text == "foo "

  test "Delete (CSI 3 ~) removes char under cursor":
    # "abc", ArrowLeft, ArrowLeft (cursor at 'b'), Delete -> "ac"
    let o = runInput("abc\x1b[D\x1b[D\x1b[3~\r")
    check o.text == "ac"

  test "Ctrl-C cancels":
    let o = runInput("foo\x03")
    check o.kind == ioCancelled

  test "Esc cancels":
    let o = runInput("\x1b")
    check o.kind == ioCancelled

  test "history: ArrowUp recalls last entry":
    let h = newHistory()
    h.entries.add "previous"
    let o = runInput("\x1b[A\r", history = h)
    check o.text == "previous"

  test "history: submitted text is appended":
    let h = newHistory()
    discard runInput("first\r", history = h)
    discard runInput("second\r", history = h)
    check h.entries == @["first", "second"]
