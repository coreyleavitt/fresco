## Raw stdin → chronos AsyncQueue[KeyEvent].
##
## Wires the pure decoder (`fresco/events`) and the termios helpers
## (`fresco/terminal/termios`) into chronos. Reads are non-blocking
## and triggered by `addReader` callbacks; bytes are decoded eagerly
## and the resulting events pushed into an unbounded AsyncQueue.
##
## ESC disambiguation: when the decoder leaves a bare ESC at the front
## of the pending buffer, a short timer (default 50 ms) is armed; if it
## fires before more bytes arrive, the ESC flushes as kEscape. Any new
## byte cancels the timer.

import std/posix
import chronos
import ./terminal/termios
import ./events
import intonaco/reactive/primitives/scope

import intonaco/journal/events as jev
import intonaco/journal/log

const DefaultEscTimeout* = 50.milliseconds

type
  KeyFilter* = proc(ev: KeyEvent): bool {.closure.}
    ## Pre-filter on the input stream. Returns `true` if the event was
    ## consumed (don't enqueue for `nextKey`); `false` to pass through.
    ## Filters run synchronously in the read callback — keep them fast.

  FilterEntry = object
    id: int
    fn: KeyFilter

  InputStream* = ref object
    fd: cint
    queue: AsyncQueue[KeyEvent]
    pending: string
    snapshot: TermiosSnapshot
    prevFlags: cint
    closed: bool
    registered: bool
    escTimeout: Duration
    escWaiter: Future[void]
    escGen: int
      ## Monotonic generation; incremented every time onReadable spawns
      ## or replaces an escWaiter. finalizeEsc captures the generation
      ## at entry and only enqueues if it still matches at exit — this
      ## prevents a phantom kEscape when sleepAsync wins the cancel
      ## race against fresh disambiguating bytes.
    closing: Future[void]
      ## Completes when stop() is called. nextKey awaits on this in
      ## parallel with the queue so pending awaiters wake on stream
      ## teardown instead of blocking forever.
    filters: seq[FilterEntry]
    nextFilterId: int
    droppedEvents*: int
      ## Number of decoded KeyEvents that the queue rejected as full.
      ## Always 0 for the default (unbounded) queue. Bounded callers
      ## can poll this between reads to detect input loss instead of
      ## getting silent drops.

  InputStreamClosedError* = object of CatchableError

proc setNonblocking(fd: cint): cint =
  result = fcntl(fd, F_GETFL, 0)
  if result < 0: return
  discard fcntl(fd, F_SETFL, result or O_NONBLOCK)

proc restoreFlags(fd: cint, flags: cint) =
  if flags >= 0:
    discard fcntl(fd, F_SETFL, flags)

proc runFilters(s: InputStream, ev: KeyEvent): bool {.gcsafe.} =
  ## Walk filters in registration order. First filter that returns
  ## true consumes the event; the rest don't see it.
  ##
  ## Iterate by index with `startLen` captured once. The previous
  ## `let snap = s.filters` form was vulnerable to Nim 2.x cursor
  ## inference making `snap` a non-retaining alias of the live seq;
  ## a filter that disposes a sibling scope synchronously triggers
  ## `removeFilter` mid-loop, mutating the live seq, and an aliased
  ## snapshot then skipped remaining filters. Bounds-check on every
  ## step so mid-loop deregistration that shifts entries doesn't
  ## walk past valid indices. Matches the iteration discipline in
  ## `notify` / `fanout`.
  ##
  ## Filter exceptions are caught + logged to stderr (a stderr write
  ## from inside the input dispatcher is acceptable as a developer
  ## diagnostic; for production silencing, wrap the filter body in
  ## try/except). The exception does NOT propagate out of the read
  ## callback — chronos's onReadable is `{.raises: [].}`.
  {.cast(gcsafe).}:
    let startLen = s.filters.len
    var i = 0
    while i < s.filters.len and i < startLen:
      let entry = s.filters[i]
      inc i
      try:
        if entry.fn(ev):
          return true
      except Exception as e:
        try:
          stderr.writeLine("fresco hotkey/filter raised: " &
                           $e.name & ": " & e.msg)
        except IOError: discard
    return false

proc enqueue(s: InputStream, evs: seq[KeyEvent]) {.gcsafe.} =
  for e in evs:
    if s.runFilters(e): continue
    try: s.queue.putNoWait(e)
    except AsyncQueueFullError:
      # Bounded-queue overflow. Increment a visible counter so callers
      # using a bounded queue can detect input loss; default queues
      # are unbounded and never hit this branch.
      inc s.droppedEvents

proc addFilter*(s: InputStream, fn: KeyFilter): int =
  ## Register a filter. Returns a handle for `removeFilter`.
  let id = s.nextFilterId
  inc s.nextFilterId
  s.filters.add FilterEntry(id: id, fn: fn)
  return id

proc removeFilter*(s: InputStream, handle: int) =
  ## Remove a filter by its handle. No-op if the handle isn't found.
  for i in 0 ..< s.filters.len:
    if s.filters[i].id == handle:
      s.filters.del i
      return

proc stop*(s: InputStream) {.gcsafe, raises: [].} =
  ## Tear down: cancel pending timer, unregister reader, restore flags
  ## and termios, uninstall signal handlers, wake any in-flight
  ## `nextKey` awaiters with InputStreamClosedError. Safe to call
  ## more than once. Genuinely `{.gcsafe, raises: [].}` so it can be
  ## called directly from chronos read callbacks.
  if s.closed: return
  s.closed = true
  if s.escWaiter != nil and not s.escWaiter.finished:
    s.escWaiter.cancelSoon()
    s.escWaiter = nil
  if not s.closing.finished:
    s.closing.complete()
  if s.registered:
    # chronos's removeReader/unregister can raise OSError. Teardown is
    # best-effort — if the fd is already gone, the registration is too.
    try:
      removeReader(AsyncFD(s.fd))
      unregister(AsyncFD(s.fd))
    except CatchableError: discard
    s.registered = false
  restoreFlags(s.fd, s.prevFlags)
  uninstallSignalHandlers()
  restoreTermios(s.snapshot)

proc finalizeEsc(s: InputStream) {.async.} =
  let myGen = s.escGen
  try:
    await sleepAsync(s.escTimeout)
  except CancelledError:
    return
  if s.closed: return
  # If onReadable bumped the generation while we were sleeping, fresh
  # bytes have arrived and we've been superseded. The new waiter (or
  # onReadable itself) will handle whatever's pending; we must not
  # emit a stale bare-ESC.
  if s.escGen != myGen: return
  if s.pending.len > 0 and s.pending[0] == '\x1b':
    let (evs, consumed) = decode(s.pending, finalize = true)
    s.enqueue(evs)
    s.pending = s.pending[consumed..^1]

proc onReadable(udata: pointer) {.gcsafe, raises: [].} =
  let s = cast[InputStream](udata)
  if s.closed: return

  var buf: array[256, char]
  var totalRead = 0
  while true:
    let n = posix.read(s.fd, addr buf[0], buf.len)
    if n < 0: break          # EAGAIN/EWOULDBLOCK — drained for this tick
    if n == 0:
      # EOF (pty HUP, stdin closed). Without this teardown the
      # dispatcher re-arms the reader and `onReadable` busy-loops on
      # zero-byte reads. Stop the stream so pending awaiters wake
      # with InputStreamClosedError and the fd is unregistered.
      if totalRead == 0:
        stop(s)   # stop is {.gcsafe, raises: [].} — direct call
      break
    inc totalRead, n
    let start = s.pending.len
    s.pending.setLen(start + n)
    for k in 0 ..< n:
      s.pending[start + k] = buf[k]

  let (evs, consumed) = decode(s.pending, finalize = false)
  s.enqueue(evs)
  if consumed > 0:
    s.pending = s.pending[consumed..^1]

  if s.escWaiter != nil and not s.escWaiter.finished:
    s.escWaiter.cancelSoon()
    s.escWaiter = nil
  if s.pending.len > 0 and s.pending[0] == '\x1b':
    inc s.escGen
    s.escWaiter = finalizeEsc(s)

proc newInputStream*(fd: cint = STDIN_FILENO,
                     queueSize: int = 0,
                     escTimeout = DefaultEscTimeout): InputStream =
  ## `fd` defaults to STDIN. `queueSize = 0` is unbounded.
  InputStream(
    fd: fd,
    queue: newAsyncQueue[KeyEvent](maxsize = queueSize),
    escTimeout: escTimeout,
    closing: newFuture[void]("InputStream.closing"),
  )

proc pushKey*(s: InputStream, ev: KeyEvent) =
  ## Synchronously feed a KeyEvent into the stream's queue. Used by
  ## the headless test substrate (`headless/input`) to drive an app
  ## without an fd — no termios, no escape-sequence encoding, no
  ## `start(stream)` needed. Any awaiter of `nextKey` will receive
  ## `ev` in FIFO order.
  ##
  ## Caller must ensure the queue is unbounded or has space (the
  ## default `queueSize = 0` is unbounded).
  s.queue.putNoWait(ev)

proc start*(s: InputStream) =
  ## Put `fd` in cbreak + non-blocking mode and register the read hook
  ## with chronos. Must be called from within a running chronos dispatcher
  ## context.
  ##
  ## Installs SIGINT/SIGTERM/SIGSEGV handlers so a crash restores
  ## termios before the process exits (CLAUDE.md non-negotiable: never
  ## leave the user's terminal in raw mode). On any exception during
  ## startup we tear back down before propagating.
  s.snapshot = enterCbreak(s.fd)
  installSignalHandlers(s.snapshot)
  try:
    s.prevFlags = setNonblocking(s.fd)
    register(AsyncFD(s.fd))
    try:
      addReader(AsyncFD(s.fd), onReadable, cast[pointer](s))
      s.registered = true
    except CatchableError:
      unregister(AsyncFD(s.fd))
      raise
  except CatchableError:
    uninstallSignalHandlers()
    restoreFlags(s.fd, s.prevFlags)
    restoreTermios(s.snapshot)
    raise

proc nextKey*(s: InputStream): Future[KeyEvent] {.async.} =
  ## **Cancel-safe** (#71): if a `CancelledError` arrives after the
  ## inner `queue.get()` has already dequeued an event but before
  ## this proc returns it, the event is pushed back to the queue so
  ## the next `nextKey` call retrieves it. Without this, the
  ## multi-source `receive:` macro's `finally:` (which calls
  ## `cancelSoon` on every losing source's nextEvent future) would
  ## silently drop a byte every time a non-stream arm wins the race.
  ## Mirrors `Mailbox.nextEvent`'s cancel-safety pattern.
  if s.closed:
    raise newException(InputStreamClosedError, "stream is closed")
  let getFut = s.queue.get()
  try:
    discard await race(FutureBase(getFut), FutureBase(s.closing))
    if not getFut.finished:
      # stop() fired; cancel the queue.get and raise.
      getFut.cancelSoon()
      raise newException(InputStreamClosedError, "stream closed mid-wait")
    let ev = getFut.read
    journalEvent: jrnl.logKeyReceived(taskTid, parentEvt, ev.summary)
    return ev
  except CancelledError:
    # Two scenarios:
    # (a) `getFut` already finished with an event before cancel
    #     reached us — requeue inline.
    # (b) `getFut` is still pending. `chronos.race` documents
    #     "On cancel futures in `futs` WILL NOT BE cancelled" —
    #     so cancelling our outer nextKey does NOT propagate to
    #     `getFut`. It keeps awaiting; when a byte later arrives,
    #     `popFirst` dequeues it and `getFut` finishes with the
    #     event — but we've already returned, so the event is
    #     orphaned. Cancel `getFut` explicitly AND install a
    #     post-finish callback that requeues whatever value it
    #     ends up holding (cancelled with value if the byte
    #     raced in; cancelled without value otherwise).
    if not getFut.finished:
      getFut.cancelSoon()
      let captured = s
      proc requeue(udata: pointer) {.gcsafe, raises: [].} =
        if getFut.finished and not getFut.failed:
          try: captured.queue.putNoWait(getFut.read)
          except CatchableError: discard
      getFut.addCallback(requeue)
    elif not getFut.failed:
      try: s.queue.putNoWait(getFut.read)
      except AsyncQueueFullError: inc s.droppedEvents
    raise

template nextEvent*(s: InputStream): Future[KeyEvent] = s.nextKey()
  ## EventSource protocol conformance (#66). The multi-source
  ## `receive: on <src> as <var>:` macro emits `await src.nextEvent()`
  ## for every source; this alias lets InputStream participate
  ## without a rename. Existing `nextKey` callers unaffected.

proc restoreEvent*(s: InputStream, ev: KeyEvent) =
  ## Cancel-recovery hook for multi-source receive (#66). When
  ## multiple sources have events ready simultaneously, all their
  ## `nextEvent` futures finish; the receive macro dispatches one
  ## and calls `restoreEvent` on the others so their values aren't
  ## silently dropped. Approximate FIFO: a value restored after
  ## concurrent input bytes lands after them.
  if s.closed: return
  try: s.queue.putNoWait(ev)
  except AsyncQueueFullError: inc s.droppedEvents
