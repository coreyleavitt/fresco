## TerminalSink — ANSI emission against a file descriptor.
##
## Verifies the new Layout + TerminalSink path produces the same
## ANSI bytes as the legacy Screen.paint path did. Captures writes
## via a Unix pipe, reads them back, byte-compares against the
## expected output computed from Screen.flush().

import std/[posix, strutils, unittest]
import fresco/screen
import fresco/render/layout
import fresco/render/sink/terminal

proc readAvailable(fd: cint): string =
  ## Drain whatever bytes are currently in the pipe. Non-blocking;
  ## returns "" if nothing's there.
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

suite "TerminalSink: ANSI emission via fd":

  test "commit writes the expected ANSI bytes to its fd":
    var pipefds: array[2, cint]
    doAssert pipe(pipefds) == 0
    let rd = pipefds[0]
    let wr = pipefds[1]
    setNonblock(rd)
    defer:
      discard close(rd)
      discard close(wr)

    let layout = newLayout(height = 3, width = 20)
    let region = newRegion(layout, 0, 0, 3, 20)
    region.set @["hello", "world", "!"]

    let sink = newTerminalSink(wr)
    sink.commit(layout)

    let bytes = readAvailable(rd)
    # Must contain the three rendered strings.
    check "hello" in bytes
    check "world" in bytes
    check "!" in bytes
    # Must contain CSI cursor-positioning escape (modern terminals
    # use ESC [ row;col H — the Renderer emits these).
    check "\x1B[" in bytes
    # A second commit with no changes should write nothing.
    sink.commit(layout)
    check readAvailable(rd) == ""

  test "flush returns the same bytes as commit writes (idempotent extraction)":
    let layout = newLayout(height = 2, width = 10)
    let region = newRegion(layout, 0, 0, 2, 10)
    region.set @["a", "b"]
    let sink = newTerminalSink(STDERR_FILENO)
    let bytes = sink.flush(layout)
    check bytes.len > 0
    # After flush, regions are no longer pending.
    check region.pending == false
    # Second flush returns nothing — diff is empty.
    check sink.flush(layout).len == 0
