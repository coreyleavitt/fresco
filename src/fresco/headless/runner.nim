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
import intonaco/reactive
import ../events
import ../input
import ../render/layout
import ../render/sink/memory
import ../inline_screen
import ../busy
import ./input as headless_input

export busy

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
  ##
  ## Fixed-sleep settling only (rfc-headless-quiescence.md §Out of
  ## scope): this overload has no `Settle`/drain-mode counterpart — a
  ## plain `Layout` has no commit batcher or InlineScreen-level idle
  ## probes to drain against. See `runHeadless(screen, app, events, ...)`
  ## below for the drain-settling overload.
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

# ---------------------------------------------------------------------------
# drainToIdle — RFC headless-quiescence, slice B6 (single-read core), B7
# (deadline + DrainTimeoutError), B8 (adversarial coverage of the single-
# read machine — no production code). Declared here, ahead of the
# InlineScreen `runHeadless` overload below, because slice B10's `Settle`
# union carries a `DrainSpec` payload and that overload's `settle:
# Settle = settleFixed()` default needs both types already in scope.
# ---------------------------------------------------------------------------

type
  DrainClause* = enum
    dcReactive    ## reactiveIdle() is false — invariant, not expected to
                  ## ever fail (model §1); see rfc §Design 3.
    dcAnimations  ## a live frame animation is registered (skipped when
                  ## spec.ignoreAnimations).
    dcCommit      ## the InlineScreen commit batcher has work in flight.
    dcDispatcher  ## the chronos dispatcher has ready callbacks pending —
                  ## the delivery-gap clause (rfc §Delivery-gap decision,
                  ## model §7): every synthetic-input delivery hop is a
                  ## ready callback, so this is exact for any app topology.
    dcBusy        ## spec.busy() reports true (skipped when spec.busy is nil).

  DrainTimeoutError* = object of AsyncTimeoutError
    failingClauses*: set[DrainClause]
      ## The clauses that were still failing at the deadline. Never empty
      ## on a raise — an idle-at-deadline read breaks instead (slice B7).

  DrainSpec* = object
    busy*: BusyPredicate
    drainTimeout*: Duration
      ## Bounds the drain (slice B7). `drainToIdle` arms a real
      ## `sleepAsync(drainTimeout)` timer once at entry — the same future
      ## is both the liveness bound (its presence in the timer heap bounds
      ## every `poll()` `select()` wait, so a pump on an otherwise-dormant
      ## dispatcher cannot block forever) and the deadline truth (no
      ## `Moment.now()` anywhere). See rfc-headless-quiescence.md
      ## "Pump & liveness" (stage-3 finding).
    ignoreAnimations*: bool

proc failingClauses(screen: InlineScreen[MemorySink], spec: DrainSpec): set[DrainClause] =
  ## Evaluate every wait clause exactly once against `screen` + `spec`.
  ## A clause disabled by `spec.ignoreAnimations` (or `spec.busy == nil`)
  ## is never evaluated and never appears in the result.
  if not reactiveIdle():
    result.incl dcReactive
  if not spec.ignoreAnimations and not animationsIdle():
    result.incl dcAnimations
  if not screen.commitIdle():
    result.incl dcCommit
  if pendingCallbacksCount() != 0:
    result.incl dcDispatcher
  if spec.busy != nil and spec.busy():
    result.incl dcBusy

proc drainToIdle*(screen: InlineScreen[MemorySink],
                  spec: DrainSpec): Future[void] {.async.} =
  ## Pump the dispatcher until `failingClauses` reads empty, then paint.
  ## Slice B7 adds the deadline + DrainTimeoutError. No stability window,
  ## no backoff (stage-3 redesign deleted both — see rfc-headless-quiescence.md
  ## "Why there is no stability window or backoff"): a single idle read is
  ## sound because `dcDispatcher` is an exact witness for framework-visible
  ## work, and a backoff has nothing to back off from once the pump is
  ## event-driven (below).
  ##
  ## Deadline liveness AND truth come from one armed timer, not
  ## `Moment.now()`: `sleepAsync(spec.drainTimeout)` is armed once at entry
  ## and cancelled on every exit path. Its presence in the timer heap
  ## bounds every `poll()` `select()` wait — a pump on an otherwise-dormant
  ## dispatcher (stage-3 finding: `stepsAsync`'s tick queue does not itself
  ## bound `select()`) now sleeps at zero CPU until either real dispatcher
  ## activity or the deadline timer fires, instead of blocking forever.
  ##
  ## The deadline is checked only after a clause evaluation, and only on
  ## the branch where that evaluation was non-empty: an idle read always
  ## breaks (succeeds) unconditionally, so an already-idle screen with a
  ## near-zero drainTimeout can never raise, and a raise's `failingClauses`
  ## can never be the empty set (same evaluation reused, no re-evaluation
  ## divergence).
  let deadlineFut = sleepAsync(spec.drainTimeout)
  defer:
    if not deadlineFut.finished:
      deadlineFut.cancelSoon()
  while true:
    let failing = failingClauses(screen, spec)
    if failing == {}:
      break
    if deadlineFut.finished:
      var e = newException(DrainTimeoutError,
                           "drain timeout; failing clauses: " & $failing)
      e.failingClauses = failing
      raise e
    await stepsAsync(1)
  screen.paint()

proc drainToIdle*(screen: InlineScreen[MemorySink],
                  busy: BusyPredicate = nil,
                  drainTimeout = 1.seconds,
                  ignoreAnimations = false): Future[void] =
  ## Convenience overload; forwards a DrainSpec.
  drainToIdle(screen, DrainSpec(busy: busy, drainTimeout: drainTimeout,
                                ignoreAnimations: ignoreAnimations))

# ---------------------------------------------------------------------------
# Settle — RFC headless-quiescence, slice B10.
#
# A discriminated union, mirroring `InlineEvent` above in this file: the
# invalid combinations (`busy`/`drainTimeout` under fixed settling,
# `perKeySettle` under drain) become unrepresentable instead of silently
# ignored (rfc §Design 5, on-thesis for compile-time-first). `skDrain`'s
# payload IS `DrainSpec` — the drain primitive's parameters and the
# harness's drain-mode policy share one declaration, so they cannot drift.
#
# `settleFixed` stays the default (rfc §Design 5, "Default"): flipping it
# is a deliberate future decision gated on amoxtli's migration, not
# something this slice changes.
# ---------------------------------------------------------------------------

type
  SettleKind* = enum skFixed, skDrain
  Settle* = object
    case kind*: SettleKind
    of skFixed:
      perKeySettle*: Duration
    of skDrain:
      drain*: DrainSpec

proc settleFixed*(perKeySettle = 1.milliseconds): Settle =
  Settle(kind: skFixed, perKeySettle: perKeySettle)

proc settleDrain*(busy: BusyPredicate = nil,
                  drainTimeout = 1.seconds,
                  ignoreAnimations = false): Settle =
  Settle(kind: skDrain, drain: DrainSpec(busy: busy, drainTimeout: drainTimeout,
                                        ignoreAnimations: ignoreAnimations))

proc runHeadless*(screen: InlineScreen[MemorySink],
                  app: HeadlessInlineApp,
                  events: seq[InlineEvent] = @[],
                  timeout: Duration = 1.seconds,
                  settle: Settle = settleFixed()
                 ): Future[HeadlessResult] {.async: (raises: [Exception]).} =
  ## Run `app` with a caller-supplied `InlineScreen[MemorySink]`. The
  ## app sets up regions on `screen` and appends committed lines;
  ## the harness drains the screen after the app finishes and surfaces
  ## both `rows` (live band) and `committedRows` (scrollback) in
  ## `HeadlessResult`.
  ##
  ## The `events` parameter is a unified Key|Resize stream (see
  ## `InlineEvent`, `keyEv`, `resizeEv`). Key events are delivered to the
  ## app via `pushKey`; Resize events call `s.setSize(h, w)`.
  ##
  ## `settle` (rfc-headless-quiescence.md §Design 5) selects how the
  ## harness waits between injected events and before the final capture:
  ##
  ##   - `settleFixed(perKeySettle)` (the default — unchanged pre-B10
  ##     behavior): sleep `perKeySettle` after each event; no wait before
  ##     the final `teardownFlush()` + `paint()` capture beyond that.
  ##   - `settleDrain(busy, drainTimeout, ignoreAnimations)`: after each
  ##     event, `await drainToIdle(screen, settle.drain)` instead of a
  ##     fixed sleep — deterministic quiescence instead of a guessed
  ##     margin (rfc §Problem). One additional drain runs before the final
  ##     capture regardless of `events.len` (so `events = @[]` still
  ##     drains). B10 scope note: a `DrainTimeoutError` from either drain
  ##     propagates out of `runHeadless` as an ordinary exception — B11
  ##     adds `SettleFailure` recording + best-effort final-drain handling;
  ##     this slice does not soften drain-mode failures.
  ##
  ## Use this overload when the consumer is an InlineScreen-based app
  ## (e.g., amoxtli's REPL) and the test needs to assert on committed
  ## scrollback output in addition to the live band.
  ##
  ## The plain `runHeadless(app, inputs, height, width, ...)` overload is
  ## unchanged and handles plain Layout-based apps (fixed-sleep only; see
  ## rfc-headless-quiescence.md §Out of scope).
  let stream = newSyntheticInputStream()
  let appFut = app(stream)

  for ev in events:
    case ev.kind
    of ievKey:
      stream.pushKey(ev.key)
    of ievResize:
      screen.setSize(ev.resizeH, ev.resizeW)
    case settle.kind
    of skFixed:
      await sleepAsync(settle.perKeySettle)
    of skDrain:
      await drainToIdle(screen, settle.drain)

  if not appFut.finished:
    discard await appFut.withTimeout(timeout)
    if not appFut.finished:
      appFut.cancelSoon()
      try: await appFut
      except CancelledError: discard
      except CatchableError: discard

  case settle.kind
  of skFixed:
    discard
  of skDrain:
    # Final pre-capture drain (rfc §Design 5): runs unconditionally in
    # drain mode, even when `events.len == 0` and the per-event loop above
    # never ran. B10 scope: not yet best-effort (that's B11's
    # `site = sfFinalDrain` recording) — a timeout here propagates like
    # any other exception.
    await drainToIdle(screen, settle.drain)

  # Final capture: drain any buffered committed lines + capture live band.
  #
  # teardownFlush drains pending log lines into sink.committedRows without
  # checking the bottom-anchor contract — safe even after a resize event
  # that leaves regions at stale positions. paint() re-renders the current
  # live band into sink.rows.
  #
  # If the app already drained the log via s.commit() (or, in drain mode,
  # the final drainToIdle above already did via its own paint()),
  # teardownFlush is a no-op (log empty) and paint() still refreshes the
  # live-band snapshot.
  screen.teardownFlush()
  screen.paint()

  result.rows = screen.sink.rows
  result.committedRows = screen.sink.committedRows
