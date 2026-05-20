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
import ./input as headless_input

type
  HeadlessApp* = proc(stream: InputStream, layout: Layout): Future[void]
                 {.async: (raises: [Exception]).}
  HeadlessResult* = object
    rows*: seq[string]
      ## The MemorySink's captured rows after the final commit. Use
      ## these to assert what the app would have rendered.

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
