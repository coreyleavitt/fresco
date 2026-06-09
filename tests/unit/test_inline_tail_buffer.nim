## test_inline_tail_buffer.nim — Slice 15: SIGSEGV-tier static tail buffer.
##
## Six deterministic unit tests:
##   1. Byte-mirror: arm → setInlineTail → inlineTailSnapshot; disarm no-ops.
##   2. Overflow drops oldest: content > InlineTailCap; only last cap bytes survive.
##   3. Flush seam: pipe-based proof that flushInlineTailNow emits exact bytes.
##   4. End-to-end via append/drain: InlineScreen integration.
##   5. Boundary: content totalling exactly InlineTailCap bytes — no bytes dropped.
##   6. Boundary: content totalling InlineTailCap + 1 bytes — exactly the oldest
##      byte is dropped (off-by-one guard for the overflow/rebuild logic).

import std/[unittest, posix, strutils]
import fresco/terminal/termios
import fresco/inline_screen
import fresco/render/sink/memory

# ─── helpers ────────────────────────────────────────────────────────────────

proc openPipe(): tuple[r, w: cint] =
  var fds: array[2, cint]
  if pipe(fds) != 0:
    raise newException(OSError, "pipe failed")
  (fds[0], fds[1])

proc readPipe(fd: cint, maxBytes: int): string =
  # Set non-blocking so reads won't hang.
  let flags = fcntl(fd, F_GETFL, 0)
  discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)
  var buf: array[16384, byte]
  result = ""
  while result.len < maxBytes:
    let n = posix.read(fd, addr buf[0], min(buf.len, maxBytes - result.len))
    if n > 0:
      for i in 0 ..< n: result.add chr(buf[i].int)
    elif errno == EAGAIN or errno == EWOULDBLOCK:
      break
    elif errno == EINTR:
      continue
    else:
      break

# ─── suite ──────────────────────────────────────────────────────────────────

suite "InlineScreen slice 15: static tail buffer":

  test "1 byte-mirror: arm / setInlineTail / snapshot / disarm no-op":
    # Use fd=1 (stdout) — we never actually write via flushInlineTailNow here;
    # we only assert the buffer contents via inlineTailSnapshot.
    armInlineTail(1)
    setInlineTail(["alpha", "beta"])
    check inlineTailSnapshot() == "alpha\nbeta\n"

    # Disarm: subsequent setInlineTail is a no-op.
    disarmInlineTail()
    setInlineTail(["x"])
    check inlineTailSnapshot() == ""

  test "2 overflow drops oldest bytes":
    # Build content whose serialized length is > InlineTailCap.
    # Each line is 100 bytes + 1 newline = 101 bytes per line.
    # 100 such lines = 10100 bytes > 8192.
    let lineBody = "ABCDEFGHIJ".repeat(10)   # 100 chars
    var lines: seq[string]
    for i in 0 ..< 100:
      lines.add(lineBody)
    armInlineTail(1)
    setInlineTail(lines)
    let snap = inlineTailSnapshot()
    check snap.len == InlineTailCap

    # The LAST InlineTailCap bytes of the serialized concat must equal snap.
    var serialized = ""
    for s in lines:
      serialized &= s & "\n"
    let expected = serialized[serialized.len - InlineTailCap .. ^1]
    check snap == expected

    disarmInlineTail()

  test "3 flush seam: pipe receives exact bytes":
    let (pipeR, pipeW) = openPipe()
    defer:
      discard posix.close(pipeR)
      discard posix.close(pipeW)

    armInlineTail(pipeW)
    setInlineTail(["crash-tail-1", "crash-tail-2"])

    # Sanity: snapshot contains the right bytes.
    check inlineTailSnapshot() == "crash-tail-1\ncrash-tail-2\n"

    # Flush via the deterministic seam (mirrors the crash-handler write path).
    flushInlineTailNow()

    # Close the write end so the reader sees EOF (avoids hanging read).
    discard posix.close(pipeW)

    let received = readPipe(pipeR, 4096)
    check received == "crash-tail-1\ncrash-tail-2\n"

    # After flush, sigTailArmed is 0 (flushInlineTailNow clears it) — disarm is a no-op.
    disarmInlineTail()

  test "4 end-to-end mirror via append/drain on InlineScreen":
    # Build an InlineScreen[MemorySink] (no real fd needed for append/drain).
    # Arm the tail buffer so setInlineTail calls inside append/drain are live.
    # Use a harmless fd (devnull) — we never call flushInlineTailNow here.
    let devNull = posix.open("/dev/null", O_WRONLY)
    defer: discard posix.close(devNull)

    let mem = newMemorySink()
    let s = newInlineScreen(mem, 10, 40, pinnedHeaderRows = 1)

    armInlineTail(devNull)

    # Append two lines — mirror should reflect both.
    s.appendLine("L1")
    s.appendLine("L2")
    check inlineTailSnapshot() == "L1\nL2\n"

    # Drain (commit flushes committed lines from MemorySink path — no output
    # written but pending is cleared; teardownFlush disarms tail).
    teardownFlush(s)
    check inlineTailSnapshot() == ""
    # After teardownFlush the tail is disarmed — subsequent setInlineTail is no-op.
    check not inlineTailArmed()

  test "5 boundary: exactly InlineTailCap bytes — nothing dropped":
    ## Content whose serialized size equals InlineTailCap exactly must be stored
    ## with zero bytes dropped. Catches off-by-one in the fits/overflow branch.
    ## We build one line of exactly (InlineTailCap - 1) chars + 1 implicit '\n'
    ## = InlineTailCap total bytes.
    let lineBody = "X".repeat(InlineTailCap - 1)
    armInlineTail(1)
    setInlineTail([lineBody])
    let snap = inlineTailSnapshot()
    check snap.len == InlineTailCap
    # Content must be the line followed by '\n'.
    check snap == lineBody & "\n"
    disarmInlineTail()

  test "6 boundary: InlineTailCap + 1 bytes — exactly 1 oldest byte dropped":
    ## Content whose serialized size is InlineTailCap + 1 must drop exactly 1
    ## byte (the very first byte of the first line). Catches off-by-one in the
    ## overflow startByte calculation under the new double-buffer layout.
    ##
    ## Build two lines:
    ##   line A: 1 char  → serialized as "A\n"       (2 bytes)
    ##   line B: (InlineTailCap - 1) chars  → serialized as B[0..cap-2]\n (cap bytes)
    ## Total = cap + 2 bytes → drop 2 oldest bytes → drop the entire "A\n".
    ## Actually let's do exactly cap+1 bytes:
    ##   line A: 0 chars → serialized as "\n"  (1 byte, the sole oldest byte)
    ##   line B: InlineTailCap - 1 chars → serialized as B...\n  (cap bytes)
    ## Total = 1 + cap = cap + 1 bytes → drop exactly 1 byte (the "\n" of A).
    ## The surviving tail = B's serialization = (cap-1) chars + '\n' = cap bytes.
    let lineA = ""
    let lineB = "Y".repeat(InlineTailCap - 1)
    armInlineTail(1)
    setInlineTail([lineA, lineB])
    let snap = inlineTailSnapshot()
    # Dropped 1 byte ("\n" from lineA); surviving = lineB + "\n" = cap bytes.
    check snap.len == InlineTailCap
    check snap == lineB & "\n"
    disarmInlineTail()
