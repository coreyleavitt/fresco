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

const DefaultEscTimeout* = 50.milliseconds

type
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

proc setNonblocking(fd: cint): cint =
  result = fcntl(fd, F_GETFL, 0)
  if result < 0: return
  discard fcntl(fd, F_SETFL, result or O_NONBLOCK)

proc restoreFlags(fd: cint, flags: cint) =
  if flags >= 0:
    discard fcntl(fd, F_SETFL, flags)

proc enqueue(s: InputStream, evs: seq[KeyEvent]) =
  for e in evs:
    try: s.queue.putNoWait(e)
    except AsyncQueueFullError: discard

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
  ## Put `fd` in cbreak + non-blocking mode and register the read hook.
  ## Must be called from within a running chronos dispatcher context.
  s.snapshot = enterCbreak(s.fd)
  s.prevFlags = setNonblocking(s.fd)
  register(AsyncFD(s.fd))
  addReader(AsyncFD(s.fd), onReadable, cast[pointer](s))
  s.registered = true

proc stop*(s: InputStream) =
  ## Tear down: cancel pending timer, unregister reader, restore flags
  ## and termios. Safe to call more than once.
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
  restoreTermios(s.snapshot)

proc nextKey*(s: InputStream): Future[KeyEvent] {.async.} =
  return await s.queue.get()
