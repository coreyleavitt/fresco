## Typed mailbox — the producer side of fresco's multi-source
## selective receive (#66).
##
## A `Mailbox[T]` is an async-queue-backed event source that
## consumers push typed values into. The receive macro accepts a
## mailbox as one of multiple `from <source> as <var>:` blocks,
## dispatching arms based on which source produced the next event.
##
##   let asks = newMailbox[PendingAsk]()
##   # producer side (RPC handler, supervisor decision, etc.):
##   asks.push(ask)
##   # consumer side:
##   receive:
##     from stream as ev: ...
##     from asks   as a:  handleAsk(a)
##
## # EventSource protocol
##
## Mailbox satisfies fresco's `EventSource[T]` duck-typed protocol:
## it exposes `nextEvent(m: Mailbox[T]): Future[T]`. Anything with
## the same signature (InputStream's `nextEvent`, a user-defined
## ref type's `nextEvent` overload) can be a `from` source in a
## receive block.
##
## # Closing
##
## `close(m)` completes any in-flight `nextEvent` awaiters with
## `MailboxClosedError`. Subsequent calls also raise. Mirrors
## InputStream's stop() shape so the two play symmetrically in
## receive blocks.

import chronos

type
  Mailbox*[T] = ref object
    queue: AsyncQueue[T]
    closing: Future[void]
    closed: bool

  MailboxClosedError* = object of CatchableError

proc newMailbox*[T](): Mailbox[T] =
  ## Construct an unbounded mailbox. Producers `push`; consumers
  ## `nextEvent` (typically through the `receive` macro).
  result = Mailbox[T](
    queue: newAsyncQueue[T](),
    closing: newFuture[void]("Mailbox.closing"))

proc push*[T](m: Mailbox[T], ev: T) =
  ## Append `ev` to the mailbox. Wakes any pending `nextEvent`
  ## awaiter. Silently dropped if the mailbox is closed — the
  ## producer typically doesn't care about lifetime races against
  ## a consumer that may have torn down (matches the off-stream-
  ## wake-source use case).
  if m.closed: return
  try: m.queue.putNoWait(ev)
  except AsyncQueueFullError: discard
    # Unbounded queue should never reach this branch; the except
    # is here only because putNoWait's exception-effect listing
    # requires it.

proc nextEvent*[T](m: Mailbox[T]): Future[T] {.async.} =
  ## Block until the next event is available. Raises
  ## `MailboxClosedError` if `close` is called while waiting.
  ##
  ## **Cancel-safe**: if a `CancelledError` arrives AFTER the queue
  ## already dequeued a value (the race that bit amoxtli — multi-
  ## source receive cancelling a losing source's nextEvent in
  ## `finally:`), the dequeued value is pushed back to the front of
  ## the queue so the next `nextEvent` retrieves it instead of
  ## losing it. Without this, the multi-source receive macro would
  ## silently drop events queued in a non-winning source.
  if m.closed:
    raise newException(MailboxClosedError, "mailbox is closed")
  let getFut = m.queue.get()
  try:
    discard await race(FutureBase(getFut), FutureBase(m.closing))
    if not getFut.finished:
      getFut.cancelSoon()
      raise newException(MailboxClosedError, "mailbox closed mid-wait")
    return getFut.read
  except CancelledError:
    # Re-queue any value the get already extracted. AsyncQueue
    # doesn't expose put-at-head; putNoWait at tail is the closest
    # FIFO-preserving option for the common case of "no other
    # producer raced in during the cancel window."
    if getFut.finished and not getFut.failed:
      try: m.queue.putNoWait(getFut.read)
      except AsyncQueueFullError: discard
    raise

proc restoreEvent*[T](m: Mailbox[T], ev: T) =
  ## Put `ev` back into the mailbox. Used by the multi-source
  ## `receive` macro: when several sources have events ready
  ## simultaneously, all their `nextEvent` futures finish — but the
  ## macro dispatches only one. The losing sources' values are
  ## handed back via `restoreEvent` so they're not silently dropped.
  ##
  ## FIFO is approximate: a value restored after other producers
  ## pushed in the same tick will land after the newer values. The
  ## common case (no concurrent push during the cancel window)
  ## preserves order.
  if m.closed: return
  try: m.queue.putNoWait(ev)
  except AsyncQueueFullError: discard

proc close*[T](m: Mailbox[T]) =
  ## Signal end-of-stream. Pending `nextEvent` calls raise
  ## `MailboxClosedError`; subsequent pushes are silently dropped.
  ## Idempotent.
  if m.closed: return
  m.closed = true
  if not m.closing.finished:
    m.closing.complete()
