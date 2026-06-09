## runHeadless — the headless test harness.
##
## Wires Layout + MemorySink + SyntheticInputStream around a user app,
## pushes input events, captures final rendered rows. The "convenience
## one-liner for headless testing" that the Phase 2 RFC committed to.
##
## The app receives `(stream, layout)` and manages its own scope. The
## harness owns the sink (memory) and synthetic stream; it does not
## know about the app's reactive setup.

import chronos
import ../events
import ../input
import ../render/layout
import ../render/sink/memory
import ../inline_screen
import ./input as headless_input

type
  HeadlessApp* = proc(stream: InputStream, layout: Layout): Future[void]
                 {.async: (raises: [Exception]).}
  HeadlessResult* = object
    rows*: seq[string]
      ## The MemorySink's captured rows after the final commit. Use
      ## these to assert what the app would have rendered.
    committedRows*: seq[string]
      ## Committed (scrollback) lines captured from an
      ## InlineScreen[MemorySink] run. Empty when using the plain
      ## `runHeadless(app, layout)` overload (no InlineScreen).
      ## Populated by `runHeadless(screen, app, events)` after the
      ## InlineScreen-level drain completes.

  InlineEventKind* = enum
    ievKey     ## A keyboard event delivered to the app via pushKey.
    ievResize  ## A terminal-resize event applied via s.setSize(h, w).

  InlineEvent* = object
    ## A scripted event in a unified Key|Resize stream for the
    ## InlineScreen runHeadless overload. Constructed via `keyEv` or
    ## `resizeEv` convenience helpers.
    case kind*: InlineEventKind
    of ievKey:
      key*: KeyEvent
    of ievResize:
      resizeH*: int
      resizeW*: int

proc keyEv*(k: KeyEvent): InlineEvent =
  ## Construct a Key event for a scripted InlineEvent stream.
  InlineEvent(kind: ievKey, key: k)

proc resizeEv*(h, w: int): InlineEvent =
  ## Construct a Resize event for a scripted InlineEvent stream.
  ## The harness applies `s.setSize(h, w)` then waits one dispatcher
  ## turn so reactive `liveZoneHeight` updates before the next event.
  InlineEvent(kind: ievResize, resizeH: h, resizeW: w)

proc runHeadless*(app: HeadlessApp,
                  inputs: seq[KeyEvent],
                  height: int = 24, width: int = 80,
                  timeout: Duration = 1.seconds,
                  perKeySettle: Duration = 1.milliseconds
                 ): Future[HeadlessResult] {.async: (raises: [Exception]).} =
  ## Run `app` against a synthetic Layout + MemorySink. Push each
  ## `KeyEvent` from `inputs` in order, giving the app `perKeySettle`
  ## time between pushes to react. Wait for the app to finish (or
  ## hit `timeout`). Then commit the layout to the memory sink and
  ## return the captured rows.
  ##
  ## The app is expected to terminate on its own (e.g., by returning
  ## when it sees a quit key). If it doesn't, the harness cancels it
  ## at the timeout — the test still gets a HeadlessResult with the
  ## state at cancellation.
  let layout = newLayout(height, width)
  let sink = newMemorySink()
  let stream = newSyntheticInputStream()

  let appFut = app(stream, layout)

  for ev in inputs:
    stream.pushKey(ev)
    await sleepAsync(perKeySettle)

  if not appFut.finished:
    # App didn't return on its own — wait up to `timeout`, then cancel.
    discard await appFut.withTimeout(timeout)
    if not appFut.finished:
      appFut.cancelSoon()
      try: await appFut
      except CancelledError: discard
      except CatchableError: discard

  sink.commit(layout)
  result.rows = sink.rows

type
  HeadlessInlineApp* = proc(stream: InputStream): Future[void]
                       {.async: (raises: [Exception]).}
    ## App proc for the InlineScreen-aware `runHeadless` overload.
    ## The caller owns the `InlineScreen[MemorySink]` and passes it
    ## externally; the app receives only the `InputStream` for input
    ## events. Layout and region setup happen in the app body via the
    ## caller-captured screen.

proc runHeadless*(screen: InlineScreen[MemorySink],
                  app: HeadlessInlineApp,
                  events: seq[InlineEvent] = @[],
                  timeout: Duration = 1.seconds,
                  perKeySettle: Duration = 1.milliseconds
                 ): Future[HeadlessResult] {.async: (raises: [Exception]).} =
  ## Run `app` with a caller-supplied `InlineScreen[MemorySink]`. The
  ## app sets up regions on `screen` and appends committed lines;
  ## the harness drains the screen after the app finishes and surfaces
  ## both `rows` (live band) and `committedRows` (scrollback) in
  ## `HeadlessResult`.
  ##
  ## The `events` parameter is a unified Key|Resize stream (see
  ## `InlineEvent`, `keyEv`, `resizeEv`). Key events are delivered to the
  ## app via `pushKey`; Resize events call `s.setSize(h, w)` and then
  ## yield one dispatcher turn (`perKeySettle`) so reactive
  ## `liveZoneHeight` and any watchResizes-style relayout can react
  ## before the next event. Passing `events = @[]` (the default) is
  ## equivalent to the old `inputs = @[]` call.
  ##
  ## Use this overload when the consumer is an InlineScreen-based app
  ## (e.g., amoxtli's REPL) and the test needs to assert on committed
  ## scrollback output in addition to the live band.
  ##
  ## The existing `runHeadless(app, inputs, height, width, ...)` overload
  ## is unchanged and handles plain Layout-based apps.
  let stream = newSyntheticInputStream()
  let appFut = app(stream)

  for ev in events:
    case ev.kind
    of ievKey:
      stream.pushKey(ev.key)
      await sleepAsync(perKeySettle)
    of ievResize:
      screen.setSize(ev.resizeH, ev.resizeW)
      # Yield one dispatcher turn so the reactive liveZoneHeight Dynamic
      # (and any watchResizes-style subscriber) updates before the next event.
      await sleepAsync(perKeySettle)

  if not appFut.finished:
    discard await appFut.withTimeout(timeout)
    if not appFut.finished:
      appFut.cancelSoon()
      try: await appFut
      except CancelledError: discard
      except CatchableError: discard

  # Final capture: drain any buffered committed lines + capture live band.
  #
  # teardownFlush drains pending log lines into sink.committedRows without
  # checking the bottom-anchor contract — safe even after a resize event
  # that leaves regions at stale positions. paint() re-renders the current
  # live band into sink.rows.
  #
  # If the app already drained the log via s.commit(), teardownFlush is a
  # no-op (log empty) and paint() still refreshes the live-band snapshot.
  screen.teardownFlush()
  screen.paint()

  result.rows = screen.sink.rows
  result.committedRows = screen.sink.committedRows
