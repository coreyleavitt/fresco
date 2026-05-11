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
import ./reactive/scope
import ./journal/events as jev
import ./journal/log

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
    filters: seq[FilterEntry]
    nextFilterId: int

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
  ## The list is *snapshotted* before iteration: a filter body that
  ## disposes its registering scope (and therefore calls removeFilter)
  ## mid-loop would otherwise corrupt index-based iteration.
  ##
  ## Filter exceptions are caught + logged to stderr (a stderr write
  ## from inside the input dispatcher is acceptable as a developer
  ## diagnostic; for production silencing, wrap the filter body in
  ## try/except). The exception does NOT propagate out of the read
  ## callback — chronos's onReadable is `{.raises: [].}`.
  {.cast(gcsafe).}:
    let snap = s.filters
    for entry in snap:
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
    except AsyncQueueFullError: discard

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

proc finalizeEsc(s: InputStream) {.async.} =
  try:
    await sleepAsync(s.escTimeout)
  except CancelledError:
    return
  if s.closed: return
  if s.pending.len > 0 and s.pending[0] == '\x1b':
    let (evs, consumed) = decode(s.pending, finalize = true)
    s.enqueue(evs)
    s.pending = s.pending[consumed..^1]

proc onReadable(udata: pointer) {.gcsafe, raises: [].} =
  let s = cast[InputStream](udata)
  if s.closed: return

  var buf: array[256, char]
  while true:
    let n = posix.read(s.fd, addr buf[0], buf.len)
    if n <= 0: break
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
    s.escWaiter = finalizeEsc(s)

proc newInputStream*(fd: cint = cint(0),
                     queueSize: int = 0,
                     escTimeout = DefaultEscTimeout): InputStream =
  ## `fd` defaults to STDIN. `queueSize = 0` is unbounded.
  InputStream(
    fd: fd,
    queue: newAsyncQueue[KeyEvent](maxsize = queueSize),
    escTimeout: escTimeout,
  )

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

proc stop*(s: InputStream) =
  ## Tear down: cancel pending timer, unregister reader, restore flags
  ## and termios, uninstall signal handlers. Safe to call more than once.
  if s.closed: return
  s.closed = true
  if s.escWaiter != nil and not s.escWaiter.finished:
    s.escWaiter.cancelSoon()
    s.escWaiter = nil
  if s.registered:
    removeReader(AsyncFD(s.fd))
    unregister(AsyncFD(s.fd))
    s.registered = false
  restoreFlags(s.fd, s.prevFlags)
  uninstallSignalHandlers()
  restoreTermios(s.snapshot)

proc nextKey*(s: InputStream): Future[KeyEvent] {.async.} =
  let ev = await s.queue.get()
  if globalJournal != nil:
    let tid = if currentScope != nil: currentScope.taskId else: jev.RootTask
    let parent = if currentScope != nil: currentScope.lastEventId else: jev.NoEvent
    try:
      let id = globalJournal.logKeyReceived(tid, parent, ev.summary)
      if currentScope != nil: currentScope.lastEventId = id
    except Exception: discard
  return ev
