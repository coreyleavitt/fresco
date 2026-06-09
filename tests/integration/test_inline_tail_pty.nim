## test_inline_tail_pty.nim — Tier-2 real-SIGSEGV test for the static tail buffer.
##
## Spawns a compiled child helper that:
##   1. Arms the tail buffer with known lines on STDERR.
##   2. Installs fresco signal handlers.
##   3. Triggers a genuine SIGSEGV.
##
## The parent runs the child in a PTY (using runInPty) and asserts that the
## crash handler flushed the tail lines to the PTY master before exit.
##
## The test uses STDERR for the tail fd because runInPty wires stderr to the
## PTY slave, making its bytes visible on the PTY master. ONLCR is suppressed
## in the child so \n bytes are not translated to \r\n on the PTY.

import std/[unittest, os, strutils]
import ./helpers/pty_subprocess

const ChildBin = "/tmp/fresco_inline_tail_segv_child"
const ChildSrc = "tests/integration/helpers/inline_tail_segv_child.nim"

proc compileChild(): bool =
  let cmd = "nim c --hints:off --warnings:off --path:src -o:" &
            ChildBin & " " & ChildSrc
  execShellCmd(cmd) == 0

suite "inline tail buffer: real SIGSEGV crash-handler flush via PTY":

  test "child compiles":
    check compileChild()

  test "SIGSEGV handler flushes tail to PTY master":
    doAssert compileChild(), "child binary failed to compile"

    # Run child in PTY. The child signals readiness then segfaults.
    # Give it 3 seconds — compilation is done; the segfault is instant.
    let (output, exitCode) = runInPty(ChildBin, 3000)

    # The crash handler flushed the tail; both lines must appear in master stream.
    check output.contains("SEGV-TAIL-A")
    check output.contains("SEGV-TAIL-B")
    # Child exits via SIGSEGV re-raise → 128+11=139 on Linux, or just nonzero.
    check exitCode != 0
