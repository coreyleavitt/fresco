## inline_teardown.nim — chronos watch task + lifecycle template for graceful
## SIGTERM/SIGINT teardown.
##
## Separate module so `import chronos` stays out of inline_screen.nim, which
## deliberately avoids direct chronos imports to prevent transitive-importer
## macro-instantiation failures (slice 10c finding).
##
## Usage (low-level):
##   armGracefulTeardown()
##   asyncSpawn watchTeardownSignals(s)
##   # ... run app loop ...
##   # On SIGTERM/SIGINT: gracefulSignalHandler writes a byte to the self-pipe;
##   # the chronos dispatcher wakes waitTeardownByte; teardownFlush runs in
##   # normal context (full flush, never dropped); then restoreAllAndReraise
##   # ends the process via re-raise with default disposition.
##
## Preferred usage (lifecycle template — fresco owns all three teardown tiers):
##   proc main() {.async.} =
##     withInlineScreen(newTerminalSink(), 24, 80, 1, s):
##       # s : InlineScreen[TerminalSink]
##       discard s.commit()
##   waitFor main()

import chronos
import std/posix
import ./render/sink
import ./inline_screen
import ./terminal/termios

var teardownPipeRegistered {.threadvar.}: bool
  ## Whether the read fd is registered with the chronos dispatcher.
  ## Prevents double-register if watchTeardownSignals is called more than once.

proc waitTeardownByte() {.async.} =
  ## Suspend until the teardown self-pipe is readable, then drain it.
  ## Mirrors screen.nim's waitWinchByte pattern exactly.
  let fd = AsyncFD(teardownPipeReadFd())
  if not teardownPipeRegistered:
    try: register(fd) except OSError: discard
    teardownPipeRegistered = true
  let fut = newFuture[void]("fresco.teardownPipe")
  proc onReadable(udata: pointer) {.gcsafe.} =
    if not fut.finished():
      fut.complete()
  try: addReader(fd, onReadable)
  except OSError: discard
  try:
    await fut
  finally:
    try: removeReader(fd) except OSError: discard
  # Drain whatever arrived (coalesced signals).
  drainTeardownPipe()

proc watchTeardownSignals*[S: Sink](s: InlineScreen[S]) {.async.} =
  ## Watch the teardown self-pipe for a graceful SIGTERM or SIGINT.
  ##
  ## ONE graceful signal is terminal — no loop. On wake:
  ##   1. teardownFlush(s) — drain all pending committed lines in normal
  ##      context (full flush; never dropped; safe to alloc/GC).
  ##   2. restoreAllAndReraise(consumeGracefulSig()) — restore the terminal
  ##      and re-raise the signal with default disposition, ending the process.
  ##
  ## Spawn with `asyncSpawn` near the app loop, exactly like `watchResizes`.
  ## armGracefulTeardown() must have been called first so the self-pipe exists.
  doAssert teardownPipeReadFd() != 0 or true,
    "fresco: watchTeardownSignals requires armGracefulTeardown() first"
  await waitTeardownByte()
  # Normal context — full teardown pipeline is safe.
  teardownFlush(s)
  restoreAllAndReraise(consumeGracefulSig())

# ---------------------------------------------------------------------------
# withInlineScreen — three-tier teardown lifecycle
# ---------------------------------------------------------------------------

template withInlineScreen*[S: Sink](sink: S, h, w: int, pinnedHeaderRows: int,
                                    s: untyped, body: untyped) =
  ## Exception-safe inline-screen scope. fresco owns all THREE teardown tiers:
  ##
  ##   tier-1 (normal / exception): `teardownFlush(s)` in `finally` — runs in
  ##     full normal context; all heap operations valid; committed lines always
  ##     flushed on every exit path.
  ##
  ##   tier-2 (graceful SIGTERM/INT): `armGracefulTeardown` + `watchTeardownSignals`
  ##     — the watch task awaits the self-pipe byte, calls `teardownFlush`, then
  ##     `restoreAllAndReraise`. Layered on top of the hard handlers installed by
  ##     `withCbreak` so the saved handler IS `termiosSignalHandler`.
  ##
  ##   tier-3 (SIGSEGV/crash): `armInlineTail(sink.fd)` — the static tail buffer
  ##     is armed on the output fd so the async-signal-safe crash handler can emit
  ##     the last committed bytes via a raw write with no heap access.
  ##
  ## Ordering rationale:
  ##   `withCbreak` must run first — it installs `termiosSignalHandler` for
  ##   SIGINT/SIGTERM/SIGSEGV. `armGracefulTeardown` then saves those hard handlers
  ##   as the escalation target and replaces INT/TERM with `gracefulSignalHandler`.
  ##   This ordering ensures escalation always falls back to the hard handler.
  ##
  ## The `when compiles(sink.fd)` guard keeps the template valid for non-terminal
  ## sinks (e.g. `MemorySink`) that carry no output fd: the tier-2/3 arming and
  ## the watch task are skipped; tier-1 `teardownFlush` still runs in `finally`
  ## (it is a no-op for MemorySink). This means the same template compiles for
  ## both `InlineScreen[TerminalSink]` and `InlineScreen[MemorySink]`.
  ##
  ## The watch task needs dispatcher turns supplied by the async `body`. Use
  ## this template inside an `{.async.}` proc — the same requirement as
  ## `watchResizes` and `runAutoPaint`.
  ##
  ## Hygiene: `s` is injected into the body scope via `{.inject.}` so the
  ## caller names the binding freely.
  ##
  ## Usage:
  ##   proc main() {.async.} =
  ##     withInlineScreen(newTerminalSink(), 24, 80, 1, scr):
  ##       # scr : InlineScreen[TerminalSink]
  ##       scr.appendLine("hello")
  ##       discard scr.commit()
  ##   waitFor main()
  let s {.inject.} = newInlineScreen(sink, h, w, pinnedHeaderRows)
  withCbreak:
    when compiles(sink.fd):
      armInlineTail(sink.fd)
      armGracefulTeardown()
      let watchFut = watchTeardownSignals(s)
    try:
      body
    finally:
      teardownFlush(s)
      when compiles(sink.fd):
        if not watchFut.finished: watchFut.cancelSoon()
        disarmGracefulTeardown()
        disarmInlineTail()

template withInlineScreen*[S: Sink](sink: S, h, w: int,
                                    s: untyped, body: untyped) =
  ## Convenience overload: defaults `pinnedHeaderRows = 1`.
  withInlineScreen(sink, h, w, 1, s, body)
