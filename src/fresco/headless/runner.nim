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
  # DrainClause / SettleFailureSite / SettleFailure declared here, ahead of
  # HeadlessResult, purely for forward-reference reasons: HeadlessResult's
  # `settleFailures` field needs `SettleFailure` (which needs `DrainClause`)
  # already in scope. `DrainTimeoutError`/`DrainSpec`/`drainToIdle` stay at
  # their original location below (RFC §Design 3) — only the enum moved.
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

  SettleFailureSite* = enum sfEvent, sfFinalDrain, sfScriptTruncated
  SettleFailure* = object
    ## A settle-time failure captured instead of raised or silently dropped
    ## (rfc-headless-quiescence.md §Design 5, "the primitive raises, the
    ## harness reports"). `sfEvent`/`sfFinalDrain` are drain timeouts
    ## (`clauses` names the still-failing `DrainClause`s at the deadline).
    ## `sfScriptTruncated` is not a drain timeout at all — it fires when the
    ## app future finishes (successfully or with an error) before the
    ## scripted `events` are fully injected, so `clauses` is always `{}`
    ## there (round-1 stage-4 H1: a successful early app exit used to drop
    ## the remaining script in silence — `settled()` read `true` over a
    ## script that only partly ran). Each site's payload is unrepresentable
    ## on the other branches — a discriminated union, not a sentinel
    ## (round 2 of the RFC rejected `eventIndex = -1`; H1 applies the same
    ## discipline to the app-death case).
    clauses*: set[DrainClause]
    case site*: SettleFailureSite
    of sfEvent:
      eventIndex*: int   ## index into the `events` seq passed to runHeadless.
    of sfFinalDrain:
      discard
    of sfScriptTruncated:
      firstUndeliveredIndex*: int
        ## index into `events` of the first event never injected. Recorded
        ## in BOTH settle modes (rfc §Design 5, H1 resolution) — the app
        ## future finishing does not distinguish success from failure here;
        ## a failure lands its own fact in `appError` separately, since a
        ## crash and a truncated script are both true at once.

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
    appError*: ref Exception
      ## Nil unless the app future failed. Populated by the
      ## `runHeadless(screen, app, events)` overload's app-finish/cancel
      ## dance (both settle kinds) — including the app-death short-circuit
      ## (rfc §Design 5, "App-death short-circuit"; H1: now shared by both
      ## settle kinds), where the app dies mid-script and injection stops.
      ## The plain `runHeadless(app, inputs, ...)` overload does not
      ## populate this field (out of scope; see rfc §Out of scope).
    settleFailures*: seq[SettleFailure]
      ## Settle-time failures recorded instead of raised or silently
      ## dropped. `sfEvent`/`sfFinalDrain` (drain timeouts) are only ever
      ## produced by `settleDrain` runs. `sfScriptTruncated` (H1: the app
      ## future finished before the script finished injecting) can occur
      ## under EITHER settle kind, since both loops share the same
      ## app-death short-circuit. Always empty for the plain Layout-based
      ## overload (fixed-sleep only; no drain machinery, no truncation
      ## tracking; out of scope — see rfc §Out of scope).
    cancelGraceExpired*: bool
      ## True iff the post-cancel `CancelGrace` wait (below) elapsed with
      ## `appFut` still not finished — the app's cancellation path is hung
      ## or swallowed the cancel and kept running. Populated by BOTH
      ## `runHeadless` overloads via the shared `teardownAppFut` routine
      ## (rfc §Design 5, "the withTimeout correction" — totality is a
      ## harness invariant, not a settle-mode-specific policy). A future
      ## abandoned in this state is neither `Failed` nor `Cancelled`
      ## (chronos: it is still `Pending`), so `appError` stays nil for it —
      ## this field is the only witness.

proc settled*(r: HeadlessResult): bool =
  ## True iff the run hit no drain timeout, the app raised nothing, and
  ## the post-cancel grace never expired on a still-live app future — the
  ## one-expression "clean run" assertion (rfc §Design 5).
  r.appError.isNil and r.settleFailures.len == 0 and not r.cancelGraceExpired

const CancelGrace* = 100.milliseconds
  ## Bounds the post-cancel wait in `teardownAppFut` below, shared by BOTH
  ## `runHeadless` overloads (rfc-headless-quiescence.md §Design 5,
  ## "CancelGrace bound" — the round-2 "fixed path stays unbounded" note is
  ## superseded; totality is a harness invariant, not a settle-mode-
  ## specific policy). Cancellation-survival cannot be witnessed in
  ## bounded time — nothing distinguishes "about to land" from "never
  ## lands" — so this grace, like `drainToIdle`'s `drainTimeout`, is a
  ## forced wall-clock deadline, not a derived one. A future still
  ## unfinished after the grace is deliberately abandoned; the capture
  ## proceeds regardless.

proc boundedAwait(fut: Future[void], bound: Duration): Future[bool]
    {.async: (raises: [Exception]).} =
  ## The TOTAL variant of `chronos.withTimeout`: wait up to `bound` for
  ## `fut` without ever cancelling it and without waiting for any
  ## cancellation to land. Returns whether `fut` finished within the
  ## bound; on `false` the future is STILL PENDING and the caller owns
  ## the abandonment decision.
  ##
  ## `chronos.withTimeout` cannot provide this: on timeout it cancels
  ## the target, but its OWN returned future resolves only once the
  ## target future actually finishes — for a future whose cancellation
  ## is swallowed, that is never, so a `withTimeout` call hangs instead
  ## of bounding anything (discovered building the teardown below; see
  ## rfc-headless-quiescence.md, "the withTimeout correction"). `race()`
  ## has no such coupling: it resolves the instant EITHER argument
  ## finishes and never touches the loser, so racing against a plain
  ## timer genuinely bounds the wait. Never cancel the `race()` future
  ## itself — this codebase's own record on chronos `race()` not
  ## propagating cancellation to children means that would leave the
  ## loser dangling uncancelled; `race()` is always awaited to
  ## completion, and the losing timer is cancelled by hand so the timer
  ## heap stays clean.
  if fut.finished:
    return true
  let timer = sleepAsync(bound)
  discard await race(fut, timer)
  if not timer.finished:
    timer.cancelSoon()
  return fut.finished

proc teardownAppFut(appFut: Future[void], timeout: Duration): Future[bool]
    {.async: (raises: [Exception]).} =
  ## Shared post-script teardown for BOTH `runHeadless` overloads: wait up
  ## to `timeout` for `appFut` to finish on its own, cancel it and wait up
  ## to `CancelGrace` more, then give up. Returns `true` iff `appFut` is
  ## still pending after the grace — the app is deliberately abandoned in
  ## that case, never read again; the caller proceeds with capture
  ## regardless (rfc §Design 5).
  if await boundedAwait(appFut, timeout):
    return false
  appFut.cancelSoon()
  result = not (await boundedAwait(appFut, CancelGrace))

type
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
  ## when it sees a quit key). If it doesn't, the harness cancels it at
  ## `timeout`, waits up to `CancelGrace` more (the shared `teardownAppFut`
  ## routine — rfc §Design 5), then gives up — the test still gets a
  ## `HeadlessResult` either way; `result.cancelGraceExpired` is true iff
  ## the app was still pending after the grace.
  ##
  ## Fixed-sleep settling only (rfc-headless-quiescence.md §Out of
  ## scope): this overload has no `Settle`/drain-mode counterpart — a
  ## plain `Layout` has no commit batcher or InlineScreen-level idle
  ## probes to drain against. See `runHeadless(screen, app, events, ...)`
  ## below for the drain-settling overload. This overload still does not
  ## populate `appError`/`settleFailures` (out of scope; see rfc §Out of
  ## scope) — only `cancelGraceExpired`, shared with that overload.
  let layout = newLayout(height, width)
  let sink = newMemorySink()
  let stream = newSyntheticInputStream()

  let appFut = app(stream, layout)

  for ev in inputs:
    stream.pushKey(ev)
    await sleepAsync(perKeySettle)

  result.cancelGraceExpired = await teardownAppFut(appFut, timeout)

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
  # DrainClause moved up to the HeadlessResult type block above (needed
  # there for SettleFailure.clauses); DrainTimeoutError/DrainSpec stay here.
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
  ##     drains).
  ##
  ## Failure semantics — the primitive raises, the harness reports (rfc
  ## §Design 5): a `DrainTimeoutError` from a per-event drain is captured
  ## as a `SettleFailure(site: sfEvent, eventIndex: <that event>)` and
  ## remaining events are NOT injected (short-circuit — under drain every
  ## framework clause reads vacuously idle once nothing is left to settle,
  ## so continuing would silently race through a broken run). A dead app
  ## future (finished, successfully or not) is the SAME short-circuit
  ## trigger in BOTH settle modes, checked before each injection (H1,
  ## round-1 stage-4: `settleFixed` used to have no short-circuit at all,
  ## and `settleDrain`'s silently dropped the tail of the script on a
  ## successful early exit) — the harness stops injecting and records
  ## `SettleFailure(site: sfScriptTruncated, firstUndeliveredIndex: <first
  ## event never injected>)`, so an early-but-successful app exit is a
  ## witnessed fact instead of a `settled() == true` false positive. The
  ## final pre-capture drain is best-effort: its timeout is recorded as
  ## `site: sfFinalDrain` instead of propagating, so `runHeadless` always
  ## returns a `HeadlessResult` — never raises `DrainTimeoutError` itself.
  ## If the app future fails (in either settle mode), its exception lands
  ## in `result.appError` IN ADDITION to any `sfScriptTruncated` failure —
  ## a crash and a truncated script are distinct facts, both recorded when
  ## both are true. Use `result.settled()` for the one-expression "clean
  ## run" check.
  ##
  ## Use this overload when the consumer is an InlineScreen-based app
  ## (e.g., amoxtli's REPL) and the test needs to assert on committed
  ## scrollback output in addition to the live band.
  ##
  ## The plain `runHeadless(app, inputs, height, width, ...)` overload
  ## handles plain Layout-based apps (fixed-sleep only; see
  ## rfc-headless-quiescence.md §Out of scope) — it does not populate
  ## `appError`/`settleFailures`, but shares this overload's
  ## `cancelGraceExpired` teardown (`teardownAppFut`, below): totality is
  ## a harness invariant, not a settle-mode-specific policy.
  let stream = newSyntheticInputStream()
  let appFut = app(stream)

  var settleFailures: seq[SettleFailure] = @[]

  case settle.kind
  of skFixed:
    for idx, ev in events:
      # App-death short-circuit (H1, round-1 stage-4): shared with skDrain
      # below — a dead app must not be raced through the remaining script.
      # Pre-H1 this branch had no short-circuit at all (it pushed into a
      # dead app's queue and slept regardless); now a successful-or-failed
      # early exit stops injection and is recorded, not dropped silently.
      # `appError` (on failure) is captured uniformly below, once the
      # app-finish/cancel dance settles.
      if appFut.finished:
        settleFailures.add SettleFailure(clauses: {}, site: sfScriptTruncated,
                                         firstUndeliveredIndex: idx)
        break
      case ev.kind
      of ievKey:
        stream.pushKey(ev.key)
      of ievResize:
        screen.setSize(ev.resizeH, ev.resizeW)
      await sleepAsync(settle.perKeySettle)
  of skDrain:
    for idx, ev in events:
      # App-death short-circuit (rfc §Design 5; H1, round-1 stage-4: now
      # recorded rather than silent): a dead app must not be raced through
      # the remaining script — under drain every framework clause goes
      # vacuously idle, so the harness would otherwise sprint through a
      # dead run in silence AND `settled()` would read `true` over a
      # script that only partly ran. `appError` (on failure) is captured
      # uniformly below, once the app-finish/cancel dance settles.
      if appFut.finished:
        settleFailures.add SettleFailure(clauses: {}, site: sfScriptTruncated,
                                         firstUndeliveredIndex: idx)
        break
      case ev.kind
      of ievKey:
        stream.pushKey(ev.key)
      of ievResize:
        screen.setSize(ev.resizeH, ev.resizeW)
      try:
        await drainToIdle(screen, settle.drain)
      except DrainTimeoutError as e:
        settleFailures.add SettleFailure(clauses: e.failingClauses,
                                         site: sfEvent, eventIndex: idx)
        break

  # Shared teardown (rfc §Design 5, "the withTimeout correction"): same
  # routine as the plain Layout overload, for both settle kinds — totality
  # is a harness invariant, not a settle-mode-specific policy.
  result.cancelGraceExpired = await teardownAppFut(appFut, timeout)

  case settle.kind
  of skFixed:
    discard
  of skDrain:
    # Final pre-capture drain (rfc §Design 5): runs unconditionally in
    # drain mode, even when `events.len == 0` and the per-event loop above
    # never ran, and even after an earlier per-event SettleFailure or app
    # death. Best-effort: a timeout here is recorded (site: sfFinalDrain)
    # instead of propagating, preserving the always-returns-a-result
    # contract both overloads already document.
    try:
      await drainToIdle(screen, settle.drain)
    except DrainTimeoutError as e:
      settleFailures.add SettleFailure(clauses: e.failingClauses,
                                       site: sfFinalDrain)

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
  result.settleFailures = settleFailures
  if appFut.failed:
    result.appError = appFut.error
