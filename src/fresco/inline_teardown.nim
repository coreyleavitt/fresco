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
##   # the chronos dispatcher wakes waitTeardownByte; completeGracefulTeardown
##   # runs teardownFlush (full flush, never dropped) in normal context, ALWAYS
##   # restores the terminal, then either re-raises a Defect teardownFlush
##   # captured (R3-2, round-3 stage-4 — supersedes the signal) or ends the
##   # process via signal re-raise with default disposition.
##
## Preferred usage (lifecycle template — fresco owns all three teardown tiers):
##   proc main() {.async.} =
##     withInlineScreen(newTerminalSink(), 24, 80, 1, s):
##       # s : InlineScreen[TerminalSink]
##       discard s.commit()
##   waitFor main()

import chronos
import std/posix
import intonaco/reactive
import ./render/sink
import ./inline_screen
import ./terminal/termios

var teardownPipeRegistered {.threadvar.}: bool
  ## Whether the read fd is registered with the chronos dispatcher.
  ## Set true when we register the fd; reset false when we unregister it
  ## (in waitTeardownByte's finally and in withInlineScreen's finally as
  ## a belt-and-suspenders reset in case cancel hasn't fired yet).

proc waitTeardownByte() {.async.} =
  ## Suspend until the teardown self-pipe is readable, then drain it.
  ## Mirrors screen.nim's waitWinchByte pattern exactly.
  ##
  ## H3 lifecycle safety: each call registers the current fd if not already
  ## registered, and unregisters in the finally — but only if `teardownPipeRegistered`
  ## is still set, since `withInlineScreenImpl`'s finally may have already
  ## unregistered and closed the fd before this (cancellation) finally runs.
  ## This pairs register/unregister per call so successive lifecycles start
  ## clean regardless of how the prior one exited.
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
    # Only clean up if WE still own the registration. `withInlineScreenImpl`'s
    # finally unregisters the fd (and `disarmGracefulTeardown` closes it)
    # synchronously, while the watch task's `cancelSoon` is delivered on a
    # LATER dispatcher turn — so this finally can run second, after the fd is
    # already gone from the selector and closed. `register` at the top is
    # gated on this same flag; the cleanup must be too, else `removeReader`/
    # `unregister` hit a stale/recycled fd and raise an `AssertionDefect`
    # ("Descriptor [N] is not registered in the selector!") — a Defect, NOT an
    # OSError, so the `except OSError` would not catch it and the process would
    # crash on teardown. Gating on the flag makes whichever finally runs first
    # do the cleanup and the other a clean no-op.
    if teardownPipeRegistered:
      teardownPipeRegistered = false
      try: removeReader(fd) except OSError: discard
      try: unregister(fd) except OSError: discard
  # Drain whatever arrived (coalesced signals).
  drainTeardownPipe()

proc completeGracefulTeardown*[S: Sink](s: InlineScreen[S], sig: cint) =
  ## Run the post-wakeup graceful-teardown sequence: drain (`teardownFlush`),
  ## ALWAYS restore terminal state (`restoreAll`), then either re-raise the
  ## captured Defect or re-deliver `sig`.
  ##
  ## R3-2 (round-3 stage-4): `teardownFlush` may itself re-raise a Defect
  ## the async commit driver captured mid-run (H2/R2-M1) — `watchTeardownSignals`
  ## used to call `teardownFlush(s)` with no guard at all, so that raise
  ## skipped `restoreAllAndReraise` entirely: `chronos`'s async-macro Defect
  ## handler (`asyncmacro.nim`'s `addDefect`) re-raises a Defect EAGERLY,
  ## right where it's caught, rather than storing it on the future — so the
  ## unguarded call let the exception fly straight past tier-2 termios
  ## restore. That is the exact worst-case failure this library exists to
  ## prevent (see CLAUDE.md's "Crash-safe termios restore" non-negotiable):
  ## a captured Defect meant the terminal was left in raw mode on the FIRST
  ## graceful SIGTERM/SIGINT, saved only by a second signal hitting the hard
  ## handler's own restore.
  ##
  ## Fixed by mirroring `withInlineScreenImpl`'s precedence doctrine
  ## (inline_screen.nim / inline_teardown.nim's `finally`): cleanup/restore
  ## always completes first; a captured Defect, when present, supersedes the
  ## signal re-raise (it never reaches `reraiseSignal`'s real
  ## `kill(getpid(), sig)`) but never skips `restoreAll`. Split out of
  ## `watchTeardownSignals` as its own proc (rather than inlined) so a test
  ## can drive this exact sequence directly, without needing a real OS
  ## signal delivery or self-pipe write.
  var pendingDefect: ref Defect = nil
  try:
    teardownFlush(s)
  except Defect as d:
    pendingDefect = d
  restoreAll()
  if pendingDefect != nil:
    raise pendingDefect
  else:
    reraiseSignal(sig)

proc watchTeardownSignals*[S: Sink](s: InlineScreen[S]) {.async.} =
  ## Watch the teardown self-pipe for a graceful SIGTERM or SIGINT.
  ##
  ## ONE graceful signal is terminal — no loop. On wake, runs
  ## `completeGracefulTeardown(s, consumeGracefulSig())` (see its own doc
  ## comment for the full drain/restore/re-raise sequence and the R3-2
  ## precedence fix).
  ##
  ## Spawn with `asyncSpawn` near the app loop, exactly like `watchResizes`.
  ## armGracefulTeardown() must have been called first so the self-pipe exists.
  doAssert gracefulArmed(),
    "fresco: watchTeardownSignals requires armGracefulTeardown() first"
  await waitTeardownByte()
  # Normal context — full teardown pipeline is safe.
  completeGracefulTeardown(s, consumeGracefulSig())

# ---------------------------------------------------------------------------
# withInlineScreen — three-tier teardown lifecycle
# ---------------------------------------------------------------------------

template withInlineScreenImpl(sink: untyped, s: untyped, body: untyped) =
  ## Private shared body for all `withInlineScreen` public overloads.
  ## At call site `s` is already bound to the constructed InlineScreen.
  ## All three teardown tiers:
  ##
  ##   tier-1 (normal / exception): `teardownFlush(s)` in `finally` — runs in
  ##     full normal context; all heap operations valid; committed lines always
  ##     flushed on every exit path. `teardownFlush` may itself re-raise a
  ##     Defect the async commit driver captured mid-run (H2/R2-M1, stage-4);
  ##     the `finally` block catches it and completes ALL remaining cleanup
  ##     (tier-2/3 disarming below) before re-raising it at the end, so a
  ##     captured Defect never leaves the watch task, self-pipe registration,
  ##     or the tail buffer in an unclean state.
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
  withCbreak:
    when compiles(sink.fd):
      armInlineTail(sink.fd)
      armGracefulTeardown()
      let watchFut = watchTeardownSignals(s)
    try:
      body
    finally:
      # R2-M1 (round-2 stage-4): teardownFlush now re-raises a pending
      # Defect (H2, round-1 stage-4) as its LAST statement, AFTER draining
      # — but a raise mid-`finally` still skips every finally statement
      # AFTER the raising call. Catch it here instead of letting it fly:
      # run every remaining cleanup step (watch-task cancel, self-pipe
      # unregister, graceful/tail disarm) unconditionally first, THEN
      # re-raise at the very end of the finally block. The Defect still
      # surfaces deterministically out of this scope (fail-fast preserved)
      # — only the ordering relative to cleanup changes.
      #
      # R3-3 (round-3 stage-4, documented, deliberate): if `body` is
      # cancelled, this `finally` runs with a `CancelledError` already
      # in flight. The `raise pendingTeardownDefect` below then executes
      # mid-unwind — Nim's raise-during-unwind semantics mean a NEW raise
      # there REPLACES the in-flight exception, so the caller observes the
      # Defect, never the CancelledError. This is the same precedence
      # doctrine as everywhere else in this file (cleanup always
      # completes first; a captured Defect, when present, wins the final
      # outcome) applied to the cancellation case specifically — chronos's
      # own cancellation propagation is a casualty of it in this one
      # compound scenario, not a separate bug. See the RFC's R3-3 addendum
      # (§2, after the R2-M1 addendum) for the residual-risk framing.
      var pendingTeardownDefect: ref Defect = nil
      try:
        teardownFlush(s)
      except Defect as d:
        pendingTeardownDefect = d
      when compiles(sink.fd):
        if not watchFut.finished: watchFut.cancelSoon()
        # H3: unregister the pipe fd from the chronos dispatcher BEFORE
        # disarmGracefulTeardown closes it. This ensures the fd number is
        # removed from the selector before the kernel can reuse it — so the
        # next lifecycle's register() call on a potentially-recycled fd number
        # succeeds cleanly. Belt-and-suspenders: waitTeardownByte's finally also
        # unregisters, but cancelSoon fires on the NEXT dispatcher turn (after
        # this finally), so we must do it here to be synchronous.
        if teardownPipeRegistered:
          try: unregister(AsyncFD(teardownPipeReadFd())) except OSError: discard
          teardownPipeRegistered = false
        disarmGracefulTeardown()
        disarmInlineTail()
      if pendingTeardownDefect != nil:
        raise pendingTeardownDefect

template withInlineScreen*[S: Sink](sink: S, h, w: int, pinnedHeaderRows: int,
                                    s: untyped, body: untyped) =
  ## Exception-safe inline-screen scope. fresco owns all THREE teardown tiers.
  ## See `withInlineScreenImpl` for the full contract documentation.
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
  withInlineScreenImpl(sink, s, body)

template withInlineScreen*[S: Sink](sink: S, h, w: int,
                                    s: untyped, body: untyped) =
  ## Convenience overload: defaults `pinnedHeaderRows = 1`.
  withInlineScreen(sink, h, w, 1, s, body)

template withInlineScreen*[S: Sink](sink: S, size: Signal[(int, int)],
                                    pinnedHeaderRows: int,
                                    s: untyped, body: untyped) =
  ## Reactive overload: constructs via `newInlineScreen(sink, size,
  ## pinnedHeaderRows)` so the SIGWINCH handler can write the size signal
  ## and `liveZoneHeight` reacts. All three teardown tiers are identical to
  ## the static `h, w` overload — only the constructor differs.
  ##
  ## Usage:
  ##   proc main() {.async.} =
  ##     let sizeSig = signalC((24, 80))
  ##     withInlineScreen(newTerminalSink(), sizeSig, 1, scr):
  ##       scr.appendLine("hello")
  ##       discard scr.commit()
  ##   waitFor main()
  let s {.inject.} = newInlineScreen(sink, size, pinnedHeaderRows)
  withInlineScreenImpl(sink, s, body)

