## inline_teardown.nim — chronos watch task for graceful SIGTERM/SIGINT teardown.
##
## Separate module so `import chronos` stays out of inline_screen.nim, which
## deliberately avoids direct chronos imports to prevent transitive-importer
## macro-instantiation failures (slice 10c finding).
##
## Usage:
##   armGracefulTeardown()
##   asyncSpawn watchTeardownSignals(s)
##   # ... run app loop ...
##   # On SIGTERM/SIGINT: gracefulSignalHandler writes a byte to the self-pipe;
##   # the chronos dispatcher wakes waitTeardownByte; teardownFlush runs in
##   # normal context (full flush, never dropped); then restoreAllAndReraise
##   # ends the process via re-raise with default disposition.

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
