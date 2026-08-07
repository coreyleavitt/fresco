## Termios save/restore + cbreak helpers.
##
## Crash safety (DESIGN.md L6) rests on two guarantees:
##
##   1. `withCbreak` restores the saved termios on every exit path
##      including exceptions, via `try/finally`.
##   2. While inside `withCbreak`, SIGINT / SIGTERM / SIGSEGV /
##      SIGABRT / SIGBUS handlers are installed that restore termios
##      *before* the signal is re-raised with default disposition.
##      SIGABRT fires on doAssert/abort(); SIGBUS on unaligned/mmap
##      faults — both can leave the terminal in raw mode without
##      these handlers.
##
## Saving against a non-TTY fd (e.g. /dev/null) is not an error: the
## snapshot just carries `valid = false` and restore becomes a no-op.

import std/[posix, termios]

type
  TermiosSnapshot* = object
    fd*: cint
    saved*: Termios
    valid*: bool

proc saveTermios*(fd: cint = STDIN_FILENO): TermiosSnapshot =
  ## Snapshot the current termios for `fd`. Returns a snapshot whose
  ## `valid` field is false when `fd` is not a terminal.
  result.fd = fd
  result.valid = tcGetAttr(fd, addr result.saved) == 0

proc restoreTermios*(s: TermiosSnapshot) =
  ## No-op when `s.valid` is false (e.g. snapshot taken against a
  ## non-TTY fd). Uses TCSAFLUSH to discard any pending unread input.
  if s.valid:
    discard tcSetAttr(s.fd, TCSAFLUSH, addr s.saved)

proc enterCbreak*(fd: cint = STDIN_FILENO): TermiosSnapshot =
  ## Save current termios and switch `fd` into cbreak: ICANON, ECHO,
  ## and ISIG cleared on the local-mode side; IXON (XON/XOFF flow
  ## control, which would steal Ctrl-Q / Ctrl-S) cleared on the input
  ## side. One-byte reads (VMIN=1, VTIME=0). Returns the snapshot the
  ## caller (or `withCbreak`) restores from.
  result = saveTermios(fd)
  if not result.valid: return
  var raw = result.saved
  let lmask = not Cflag(ICANON or ECHO or ISIG)
  let imask = not Cflag(IXON)
  raw.c_lflag = raw.c_lflag and lmask
  raw.c_iflag = raw.c_iflag and imask
  raw.c_cc[VMIN] = cchar(1)
  raw.c_cc[VTIME] = cchar(0)
  discard tcSetAttr(fd, TCSAFLUSH, addr raw)

# --- signal-safe restore --------------------------------------------------

# Stack of snapshots so nested cbreak scopes (e.g. a confirm prompt
# inside an already-raw program) each get their *original* termios
# back if a signal fires before they cleanly exit. The fatal-signal
# handler walks the stack top-down restoring each saved state.

const MaxSignalSnapshots* {.intdefine.} = 16
  ## Bound on simultaneously-nested cbreak scopes the signal handler
  ## can restore. Configurable via `-d:MaxSignalSnapshots=N`. Past
  ## the bound, snapshots are silently not stored (depth counter
  ## keeps pairing correct). Deep nesting isn't a real workload —
  ## the bound exists to keep the handler signal-safe (no alloc).

# All state for the signal-handler stack lives in threadvars. fresco is
# single-thread by design (one chronos dispatcher per thread), so this
# is semantically equivalent to plain globals — but Nim's gcsafe
# inference treats threadvars as gcsafe, which lets install/uninstall
# (and therefore `stop()` in input.nim) be genuinely gcsafe without
# `{.cast(gcsafe).}` escape hatches at the call site.
#
# **Multi-thread caveat for embedders:** POSIX delivers fatal signals
# to *some* thread in the process, not necessarily the one that called
# `installSignalHandlers`. If embedded in a multi-threaded host and a
# signal arrives on a thread that never installed handlers, that
# thread's `snapshotStack` is empty and the handler skips termios
# restore — leaving the user's terminal in raw mode. Single-thread
# apps (fresco's design target) are unaffected. Proper multi-thread
# safety would require a shared restore stack with its own lock,
# which conflicts with the signal-safe (no-alloc) invariant.
var snapshotStack {.threadvar.}: array[MaxSignalSnapshots, TermiosSnapshot]
var snapshotDepth {.threadvar.}: int

type SigHandler = proc(sig: cint) {.noconv.}
var prevSigInt  {.threadvar.}: SigHandler
var prevSigTerm {.threadvar.}: SigHandler
var prevSigSegv {.threadvar.}: SigHandler
var prevSigAbrt {.threadvar.}: SigHandler
var prevSigBus  {.threadvar.}: SigHandler

# --- async-signal-safe alt-screen leave -------------------------------------
#
# These threadvars mirror the termios-restore state above. They must be
# plain C-compatible types (cint / cint-as-bool) so the signal handler can
# read and write them without any Nim GC interaction.
#
# `sigAltScreenFd` holds the output fd to write the leave sequence on.
# It is set by `markAltScreenEntered` (called from AltScreen.enter) and
# cleared by `markAltScreenLeft` (called from AltScreen.leave / finally).
#
# `sigAltScreenActive` is a cint used as a boolean flag (0 = not entered,
# 1 = entered). The signal handler emits the leave sequence only when this
# is non-zero. Plain assignment is async-signal-safe on all targets.
var sigAltScreenFd     {.threadvar.}: cint   ## output fd, or -1 when none
var sigAltScreenActive {.threadvar.}: cint   ## 1 when alt-screen is live

# Compile-time constant byte buffer for `\x1b[?1049l` — no heap alloc.
# Using a `array[N, byte]` lets us pass `addr` directly to the POSIX
# write() syscall, which is on the async-signal-safe list (POSIX.1-2017).
const AltScreenLeaveBytes*: array[8, byte] =
  [0x1b'u8, 0x5b, 0x3f, 0x31, 0x30, 0x34, 0x39, 0x6c]
  # ESC  [    ?    1    0    4    9    l

proc markAltScreenEntered*(fd: cint) {.gcsafe, raises: [].} =
  ## Record that the alternate-screen buffer has been entered on `fd`.
  ## Called by AltScreen.enter AFTER the ?1049h write succeeds.
  ## Setting two plain cint threadvars is async-signal-safe by assignment.
  sigAltScreenFd     = fd
  sigAltScreenActive = 1

proc markAltScreenLeft*() {.gcsafe, raises: [].} =
  ## Clear the alt-screen signal state. Called by AltScreen.leave and
  ## by withAltScreen's finally block so normal exit doesn't double-emit.
  sigAltScreenActive = 0
  sigAltScreenFd     = -1

# --- async-signal-safe inline-tail buffer (tier-3 teardown contract) --------
#
# Mirrors the committed `ScrollbackLog.pending` tail in already-serialized
# bytes. Maintained in HEALTHY context (LogSink.append pushes; drain pops).
# On SIGSEGV/SIGABRT/SIGBUS the handler does one raw write — no heap read,
# no alloc, no GC call. Same trust model as the alt-screen const byte buffer.
#
# Layout (double-buffer design — M2 TOCTOU fix):
#   sigTailBufs[0..1]  — two fixed byte arrays; only one is "active" at a time
#   sigTailLens[0..1]  — valid byte count for each buffer
#   sigTailActive      — index of the buffer currently live for the handler (0 or 1)
#   sigTailArmed       — 1 when an inline screen is armed
#   sigTailFd          — output fd (-1 when disarmed)
#
# setInlineTail writes into the INACTIVE buffer (1 - sigTailActive), sets its
# length, then stores sigTailActive as the single last atomic flip. The crash
# handler reads sigTailActive → buffer + length — always a complete, consistent
# snapshot (old or new, never a hybrid of both).

const InlineTailCap* = 8192
  ## Maximum bytes held in each static crash-flush tail buffer slot.
  ## On overflow the OLDEST bytes are dropped so the NEWEST committed
  ## output survives into the crash handler's single raw write.

var sigTailBufs   {.threadvar.}: array[2, array[InlineTailCap, byte]]
var sigTailLens   {.threadvar.}: array[2, cint]
var sigTailActive {.threadvar.}: cint   ## index of the live buffer (0 or 1)
var sigTailArmed  {.threadvar.}: cint   ## 1 when an inline screen is armed
var sigTailFd     {.threadvar.}: cint

proc armInlineTail*(fd: cint) {.gcsafe, raises: [].} =
  ## Arm the static tail buffer for `fd`. Called by `withInlineScreen` /
  ## armInlineTailBuffer after the screen is constructed.
  ## Resets both buffer slots so no stale bytes from a previous session
  ## can bleed through.
  sigTailFd      = fd
  sigTailLens[0] = 0
  sigTailLens[1] = 0
  sigTailActive  = 0
  sigTailArmed   = 1

proc disarmInlineTail*() {.gcsafe, raises: [].} =
  ## Disarm the tail buffer. Called on normal teardown so the crash
  ## handler does not emit stale bytes from a previous session.
  ## After this call inlineTailArmed() returns false and
  ## setInlineTail() is a no-op.
  sigTailArmed   = 0
  sigTailFd      = -1
  sigTailLens[0] = 0
  sigTailLens[1] = 0

proc setInlineTail*(lines: openArray[string]) {.gcsafe, raises: [].} =
  ## REBUILD the tail buffer from `lines` (no incremental update — a full
  ## rebuild avoids any desync between the mirror and the real pending seq).
  ## Each line is followed by 0x0A (newline). On overflow the OLDEST bytes
  ## are dropped so the buffer holds the LAST InlineTailCap bytes.
  ## No-op when disarmed (sigTailArmed == 0). Alloc-free: writes directly
  ## into the fixed array byte-by-byte.
  ##
  ## TOCTOU safety (double-buffer): writes into the INACTIVE slot
  ## (1 - sigTailActive), commits the length, then flips sigTailActive last.
  ## The crash handler always reads a complete, consistent snapshot — old or
  ## new, never a hybrid of the two.
  if sigTailArmed == 0: return

  # Select the INACTIVE slot to write into.
  let inactive = 1 - sigTailActive

  # First pass: measure total length so we know whether to truncate.
  var total = 0
  for s in lines:
    total += s.len + 1   # +1 for '\n'

  if total == 0:
    sigTailLens[inactive] = 0
    # Atomic flip: make the (now-empty) inactive slot the live one.
    sigTailActive = inactive
    return

  if total <= InlineTailCap:
    # Fits entirely: fill inactive slot from position 0.
    var pos = 0
    for s in lines:
      for ch in s:
        sigTailBufs[inactive][pos] = ch.byte
        inc pos
      sigTailBufs[inactive][pos] = 0x0A
      inc pos
    sigTailLens[inactive] = cint(pos)
  else:
    # Overflow: keep only the LAST InlineTailCap bytes.
    # We walk through the serialized sequence twice:
    #   1st pass: find the byte-offset where the surviving tail starts.
    #   2nd pass: fill sigTailBufs[inactive] from that offset.
    let dropBytes = total - InlineTailCap
    # Walk through lines to find which line/byte we start keeping from.
    var bytesSeen = 0
    var startLine = 0
    var startByte = 0   # byte offset within startLine's "line\n" string
    var found = false
    for li in 0 ..< lines.len:
      let lineLen = lines[li].len + 1  # +1 for newline
      if bytesSeen + lineLen > dropBytes:
        startLine = li
        startByte = dropBytes - bytesSeen
        found = true
        break
      bytesSeen += lineLen
    if not found:
      # All lines fit in drop zone — should not happen given total > InlineTailCap
      # but be safe.
      sigTailLens[inactive] = 0
      sigTailActive = inactive
      return
    # Fill inactive slot with the surviving tail.
    var pos = 0
    for li in startLine ..< lines.len:
      let s = lines[li]
      let lineLen = s.len + 1
      let skip = if li == startLine: startByte else: 0
      # Emit bytes from `skip` in the "line\n" sequence.
      var byteInLine = 0
      while byteInLine < lineLen and pos < InlineTailCap:
        if byteInLine >= skip:
          if byteInLine < s.len:
            sigTailBufs[inactive][pos] = s[byteInLine].byte
          else:
            sigTailBufs[inactive][pos] = 0x0A
          inc pos
        inc byteInLine
    sigTailLens[inactive] = cint(pos)

  # Atomic flip: the inactive slot is now complete; make it the live one.
  sigTailActive = inactive

# --- test seams (no real SIGSEGV needed) ------------------------------------

proc inlineTailSnapshot*(): string {.gcsafe.} =
  ## Return the current live tail buffer contents as a string (for test assertions).
  ## Reads sigTailBufs[sigTailActive][0 ..< sigTailLens[sigTailActive]] into a new Nim string.
  if sigTailArmed == 0: return ""
  let idx = sigTailActive
  let n = sigTailLens[idx]
  if n <= 0: return ""
  result = newString(n)
  for i in 0 ..< n:
    result[i] = chr(sigTailBufs[idx][i])

proc flushInlineTailNow*() {.gcsafe, raises: [].} =
  ## Runs ONLY the handler's tail-write block against sigTailFd, WITHOUT
  ## termios restore or re-raise. Lets tests point sigTailFd at a pipe and
  ## assert the exact bytes the crash handler would emit, deterministically.
  let idx = sigTailActive
  let tailLen = sigTailLens[idx]
  if sigTailArmed != 0 and sigTailFd >= 0 and tailLen > 0:
    sigTailArmed = 0  # test-and-clear FIRST — prevents double-emit on re-entrant call
    var remaining = int(tailLen)
    var offset = 0
    while remaining > 0:
      let n = posix.write(sigTailFd, addr sigTailBufs[idx][offset], remaining)
      if n > 0:
        offset += n
        remaining -= n
      elif errno == EINTR:
        continue
      else:
        break

proc termiosSignalHandler(sig: cint) {.noconv.} =
  # --- Tier-3 teardown contract: flush the pre-serialized inline tail -------
  #
  # If an inline screen is armed and the buffer has content, emit it now via
  # a single raw POSIX write loop — no alloc, no heap read, no GC call.
  # This is the static-tail-buffer flush described in the teardown contract
  # (RFC S5 slice 15). The alt-screen and inline-tail surfaces are mutually
  # exclusive, so ordering between the two blocks is moot.
  #
  # ASYNC-SIGNAL-SAFE: cint reads, fixed array addr, raw POSIX write().
  # Double-buffer: read sigTailActive once; that slot is always complete
  # (setInlineTail flips it only after the inactive slot is fully written).
  let tailIdx = sigTailActive
  let tailLen = sigTailLens[tailIdx]
  if sigTailArmed != 0 and sigTailFd >= 0 and tailLen > 0:
    sigTailArmed = 0  # test-and-clear FIRST — prevents double-emit on re-entrant signal
    var tailRemaining = int(tailLen)
    var tailOffset = 0
    while tailRemaining > 0:
      let n = posix.write(sigTailFd, addr sigTailBufs[tailIdx][tailOffset], tailRemaining)
      if n > 0:
        tailOffset += n
        tailRemaining -= n
      elif errno == EINTR:
        continue
      else:
        break

  # Emit ?1049l FIRST (before termios restore) so the terminal returns to
  # the primary buffer before we hand control back to cooked mode. Only
  # emit when alt-screen was actually entered — the flag prevents the
  # sequence appearing for programs that never called enter().
  #
  # ASYNC-SIGNAL-SAFE: const array on the stack (no heap), raw POSIX
  # write() syscall, plain cint reads. No Nim GC calls anywhere in
  # this path.
  if sigAltScreenActive != 0 and sigAltScreenFd >= 0:
    # Stack-local copy of the const — no heap alloc.
    var buf = AltScreenLeaveBytes
    var remaining = buf.len
    var offset = 0
    while remaining > 0:
      let n = posix.write(sigAltScreenFd, addr buf[offset], remaining)
      if n > 0:
        offset += n
        remaining -= n
      elif errno == EINTR:
        continue
      else:
        break
    sigAltScreenActive = 0

  # Restore innermost-first: each stored scope undoes its own change
  # so the final state is the termios as of process startup. When
  # depth exceeded MaxSignalSnapshots, we restore from the first
  # `MaxSignalSnapshots` only — better than reading uninitialized
  # array slots, and the outermost original termios is always stored.
  let top = min(snapshotDepth, MaxSignalSnapshots) - 1
  for i in countdown(top, 0):
    restoreTermios(snapshotStack[i])
  signal(sig, SIG_DFL)
  discard kill(getpid(), sig)

proc installSignalHandlers*(s: TermiosSnapshot) {.gcsafe, raises: [].} =
  ## Register restore-on-fatal-signal hooks for SIGINT/SIGTERM/SIGSEGV/
  ## SIGABRT/SIGBUS. Nested install calls push onto a stack so the
  ## original termios of each scope is preserved through fatal-signal
  ## restore. Snapshots beyond MaxSignalSnapshots (16) are silently
  ## *not stored*, but the depth counter still increments — pairing
  ## with uninstall stays correct even at extreme nesting. Deep nesting
  ## is not a real workload; the bound exists to keep this signal-safe
  ## (no alloc).
  ##
  ## SIGABRT covers Nim's doAssert/abort(); SIGBUS covers unaligned/mmap
  ## faults. Both previously dumped core with the terminal in raw mode.
  if snapshotDepth < MaxSignalSnapshots:
    snapshotStack[snapshotDepth] = s
  inc snapshotDepth
  if snapshotDepth == 1:
    # `signal()` returns the prior handler; capture so uninstall can
    # restore the caller's original disposition instead of SIG_DFL.
    prevSigInt  = cast[SigHandler](signal(SIGINT,  termiosSignalHandler))
    prevSigTerm = cast[SigHandler](signal(SIGTERM, termiosSignalHandler))
    prevSigSegv = cast[SigHandler](signal(SIGSEGV, termiosSignalHandler))
    prevSigAbrt = cast[SigHandler](signal(SIGABRT, termiosSignalHandler))
    prevSigBus  = cast[SigHandler](signal(SIGBUS,  termiosSignalHandler))

proc uninstallSignalHandlers*() {.gcsafe, raises: [].} =
  ## Pop one nest level; restore the caller's prior handlers (or
  ## SIG_DFL if none were installed before us) only when the stack
  ## is empty. Mirrors `installSignalHandlers` exactly so the pairing
  ## stays correct whether or not the corresponding install actually
  ## stored its snapshot in the bounded array.
  if snapshotDepth > 0: dec snapshotDepth
  if snapshotDepth == 0:
    discard signal(SIGINT,
      if prevSigInt  != nil: prevSigInt  else: SIG_DFL)
    discard signal(SIGTERM,
      if prevSigTerm != nil: prevSigTerm else: SIG_DFL)
    discard signal(SIGSEGV,
      if prevSigSegv != nil: prevSigSegv else: SIG_DFL)
    discard signal(SIGABRT,
      if prevSigAbrt != nil: prevSigAbrt else: SIG_DFL)
    discard signal(SIGBUS,
      if prevSigBus  != nil: prevSigBus  else: SIG_DFL)
    prevSigInt = nil; prevSigTerm = nil; prevSigSegv = nil
    prevSigAbrt = nil; prevSigBus = nil

template withCbreak*(fd: cint, body: untyped) =
  let snap = enterCbreak(fd)
  installSignalHandlers(snap)
  try:
    body
  finally:
    uninstallSignalHandlers()
    restoreTermios(snap)

template withCbreak*(body: untyped) =
  withCbreak(STDIN_FILENO, body)

# ---------------------------------------------------------------------------
# Tier-2 teardown contract: graceful SIGTERM/SIGINT → self-pipe → dispatcher
# ---------------------------------------------------------------------------
#
# Layered on TOP of installSignalHandlers (which installs termiosSignalHandler
# as the hard path). armGracefulTeardown saves the current INT/TERM handlers
# (= termiosSignalHandler after withCbreak) and replaces them with
# gracefulSignalHandler. On the FIRST signal the graceful handler writes one
# byte to a self-pipe and returns — the chronos dispatcher wakes, calls
# teardownFlush (normal context, full flush), then finishGracefulTeardown
# (restoreAll, then raise a captured Defect or reraiseSignal — called by
# inline_teardown.nim's completeGracefulTeardown).
# On a SECOND signal (escalation) or when not armed, the saved hard handler
# is called directly (static-buffer flush + restore + die).
#
# async-signal-safety: gracefulSignalHandler does ONLY cint reads/writes and
# one POSIX write() syscall — zero alloc, zero GC interaction.

var teardownPipe       {.threadvar.}: array[2, cint]   # [read, write]
var teardownPipeOpen   {.threadvar.}: cint   # 1 when the pipe fds are valid
var sigGracefulArmed   {.threadvar.}: cint   # 1 while an inline lifecycle owns INT/TERM
var sigGracefulPending {.threadvar.}: cint   # 1 once a first graceful signal is in flight
var sigGracefulSig     {.threadvar.}: cint   # the delivered signal number
var prevIntGraceful  {.threadvar.}: SigHandler   # saved prior INT handler
var prevTermGraceful {.threadvar.}: SigHandler   # saved prior TERM handler

proc restoreTermiosStack*() {.gcsafe, raises: [].} =
  ## Restore the full termios snapshot stack (innermost-first). Shared by
  ## the hard signal handler and the normal-context `restoreAll`.
  ## Safe to call from signal context (reads fixed arrays + cint, calls
  ## tcSetAttr which is async-signal-safe per POSIX).
  let top = min(snapshotDepth, MaxSignalSnapshots) - 1
  for i in countdown(top, 0):
    restoreTermios(snapshotStack[i])

proc gracefulSignalHandler(sig: cint) {.noconv.} =
  # async-signal-safe: cint reads/writes + one POSIX write() only.
  if sigGracefulArmed == 0:
    # Not armed — fall through to the saved prior handler.
    if sig == SIGINT:
      if prevIntGraceful != nil: prevIntGraceful(sig)
      else: termiosSignalHandler(sig)
    else:
      if prevTermGraceful != nil: prevTermGraceful(sig)
      else: termiosSignalHandler(sig)
    return
  if sigGracefulPending != 0:
    # Escalation: second signal before dispatcher drained — hard path.
    if sig == SIGINT:
      if prevIntGraceful != nil: prevIntGraceful(sig)
      else: termiosSignalHandler(sig)
    else:
      if prevTermGraceful != nil: prevTermGraceful(sig)
      else: termiosSignalHandler(sig)
    return
  # First graceful signal: mark pending, record sig, wake dispatcher.
  sigGracefulPending = 1
  sigGracefulSig = sig
  if teardownPipeOpen != 0:
    var b = byte('t')
    discard write(teardownPipe[1], addr b, 1)
  # Return — do NOT die. The chronos dispatcher will run teardownFlush.

proc armGracefulTeardown*() {.gcsafe, raises: [].} =
  ## Open the teardown self-pipe (if not already open), reset the pending
  ## flag, save the current SIGINT/SIGTERM handlers, and install the
  ## graceful handler. Must be called AFTER installSignalHandlers (i.e.
  ## inside withCbreak body) so the saved handlers are termiosSignalHandler.
  if teardownPipeOpen == 0:
    discard pipe(teardownPipe)
    discard fcntl(teardownPipe[0], F_SETFL, O_NONBLOCK)
    discard fcntl(teardownPipe[1], F_SETFL, O_NONBLOCK)
    teardownPipeOpen = 1
  sigGracefulPending = 0
  prevIntGraceful  = cast[SigHandler](signal(SIGINT,  gracefulSignalHandler))
  prevTermGraceful = cast[SigHandler](signal(SIGTERM, gracefulSignalHandler))
  sigGracefulArmed = 1

proc disarmGracefulTeardown*() {.gcsafe, raises: [].} =
  ## Restore the saved INT/TERM handlers and close the self-pipe. Called
  ## on normal teardown (after `completeGracefulTeardown` returns to
  ## withCbreak's finally, or on early exit without a signal).
  ##
  ## R4-5 (round-4 stage-4): idempotence guard — a second call while already
  ## disarmed is a no-op instead of re-closing the (already-closed) pipe fds
  ## or clobbering `prevIntGraceful`/`prevTermGraceful` with SIG_DFL.
  if sigGracefulArmed == 0: return
  sigGracefulArmed = 0
  discard signal(SIGINT,  if prevIntGraceful  != nil: prevIntGraceful  else: SIG_DFL)
  discard signal(SIGTERM, if prevTermGraceful != nil: prevTermGraceful else: SIG_DFL)
  prevIntGraceful  = nil
  prevTermGraceful = nil
  sigGracefulPending = 0
  if teardownPipeOpen != 0:
    teardownPipeOpen = 0
    for i in 0 .. 1:
      discard posix.close(teardownPipe[i])

proc teardownPipeReadFd*(): cint {.gcsafe.} =
  ## Return the read end of the teardown self-pipe.
  teardownPipe[0]

proc cbreakDepth*(): int {.gcsafe, raises: [].} =
  ## Current nesting depth of active `withCbreak` scopes (i.e. how many
  ## cbreak snapshots are on the signal-handler stack). Test seam: lets
  ## tests assert that withCbreak (and therefore withAltScreen post-H5)
  ## correctly installs/uninstalls the signal handlers.
  snapshotDepth

proc inlineTailArmed*(): bool {.gcsafe, raises: [].} =
  ## True when the static inline-tail buffer is currently armed.
  ## Test seam: lets tests assert arm/disarm pairing without reading private state.
  sigTailArmed != 0

proc gracefulArmed*(): bool {.gcsafe, raises: [].} =
  ## True when the graceful SIGTERM/INT teardown is currently armed.
  ## Test seam: lets tests assert arm/disarm pairing without reading private state.
  sigGracefulArmed != 0

proc drainTeardownPipe*() {.gcsafe, raises: [].} =
  ## Non-blocking drain of the teardown self-pipe. Clears any byte(s)
  ## written by gracefulSignalHandler. Mirrors winchByte drain in screen.nim.
  var buf: array[64, byte]
  while true:
    let n = posix.read(teardownPipe[0], addr buf[0], buf.len)
    if n <= 0: break

proc consumeGracefulSig*(): cint {.gcsafe.} =
  ## Return the signal number that triggered the graceful teardown.
  sigGracefulSig

proc restoreAll() {.gcsafe, raises: [].} =
  ## Normal-context restore: emit ?1049l if alt-screen active, restore the
  ## full termios stack, and disarm the graceful handler (cleans up the
  ## self-pipe). Called from the chronos watch task AFTER teardownFlush —
  ## this bypasses withCbreak's finally, so we must do the terminal
  ## restore ourselves. Normal context (not a signal handler) so no
  ## async-signal-safety constraint, but we keep it simple.
  ##
  ## Private — the only caller is `finishGracefulTeardown` below, which
  ## composes this with `reraiseSignal` in the correct order. R3-2
  ## (round-3 stage-4) split this out of the former `restoreAllAndReraise`;
  ## R5-M1 (round-5) collapsed the two halves back into one exported
  ## composition and made both halves module-private, so the ordering is
  ## now structural rather than runtime-checked.

  # CRASH-PATH tail flush. On the graceful (tier-2) path teardownFlush MUST
  # have been called before this proc and must have explicitly disarmed the
  # inline tail via disarmInlineTail() — making this call a structural no-op.
  # On the crash (tier-3) path (SIGSEGV/SIGABRT/SIGBUS) teardownFlush never
  # ran and the tail is still armed, so flushInlineTailNow() emits it.
  # Either way: no double-emit and nothing silently dropped.
  flushInlineTailNow()

  # Leave alt-screen if entered.
  if sigAltScreenActive != 0 and sigAltScreenFd >= 0:
    var buf = AltScreenLeaveBytes
    var remaining = buf.len
    var offset = 0
    while remaining > 0:
      let n = posix.write(sigAltScreenFd, addr buf[offset], remaining)
      if n > 0:
        offset += n
        remaining -= n
      elif errno == EINTR:
        continue
      else:
        break
    sigAltScreenActive = 0

  # Restore the termios stack.
  restoreTermiosStack()

  # Disarm the graceful handler (cleans up pipe).
  disarmGracefulTeardown()

proc reraiseSignal(sig: cint) {.gcsafe, raises: [].} =
  ## Re-deliver `sig` with default disposition — the final step of the
  ## graceful teardown path, once `restoreAll` has already run. Private —
  ## the only caller is `finishGracefulTeardown` below, which always calls
  ## `restoreAll()` first, so the ordering is structural (a single
  ## composition over two private halves) rather than a runtime-checked
  ## contract. See R5-M1 (round-5).
  discard signal(sig, SIG_DFL)
  discard kill(getpid(), sig)

proc finishGracefulTeardown*(sig: cint; pendingDefect: ref Defect)
    {.raises: [Defect].} =
  ## The sole exported composition of the graceful-teardown finish sequence:
  ## always restore the terminal, then either surface a captured Defect or
  ## re-deliver the OS signal. Supersedes the round-4 runtime ordering guard
  ## (a `restoreAllCompleted` threadvar + `doAssert` in `reraiseSignal`) —
  ## per the compile-time-first non-negotiable, an invariant the module
  ## system CAN make unrepresentable (private halves, one call site) should
  ## not be left to a runtime check. `reraiseSignal`'s `kill(getpid(), sig)`
  ## re-delivers the signal but this proc does not itself raise as a result
  ## of that branch — the process typically dies from the re-delivered
  ## signal before returning, but nothing here raises a Nim exception for
  ## it. The only way this proc raises is `pendingDefect` being non-nil.
  restoreAll()
  if pendingDefect != nil:
    raise pendingDefect
  else:
    reraiseSignal(sig)
