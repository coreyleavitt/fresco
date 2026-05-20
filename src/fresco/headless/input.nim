## SyntheticInputStream — drive a fresco app's input loop without an fd.
##
## Existing `InputStream` reads bytes from a file descriptor and parses
## them into `KeyEvent`s asynchronously. For headless testing, going
## through the fd path means writing terminal escape sequences and
## hoping the parser interprets them — a lot of ceremony for "I want
## to send `Key('q')`."
##
## SyntheticInputStream is a no-fd constructor that produces an
## ordinary `InputStream` (so `nextKey()` works the same way),
## populated via a direct `pushKey` helper. No termios, no fd
## registration, no parser.

import ../input
import ../events

export input.InputStream, input.nextKey, input.stop, input.pushKey
export events

proc newSyntheticInputStream*(): InputStream =
  ## A no-fd InputStream. Skip `start(stream)` — fd machinery isn't
  ## needed. Use `pushKey(stream, ev)` to feed synthetic events.
  ## `nextKey(stream)` awaits them as usual.
  ##
  ## The internal queue is unbounded by default (queueSize=0). For
  ## bounded synthetic streams (e.g., to test backpressure), construct
  ## via `newInputStream(fd = -1, queueSize = N)` directly.
  newInputStream(fd = -1)
