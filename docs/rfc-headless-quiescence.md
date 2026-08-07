# RFC: Headless quiescence — drain-to-idle settling for `runHeadless`

**Status:** draft — architect rounds 1 + 2 applied (4-lens reviews); the round-2 fork (input-delivery gap fix) **resolved for option (A)** after upstream due diligence (§Delivery-gap decision). No open forks; ready for stage 3.
**Upstream request:** `amoxtli/docs/rfc/0015-track1-fresco-quiescence-request.md` (Track 1, blocks WS-A(1))
**Repos touched:** chronos fork (`pendingCallbacksCount` accessor) + intonaco (read-only accessors) → fresco (`render/layout` consolidation, `inline_screen` probes, `busy` module, `headless/runner` driver).

## Vocabulary

Three name families, each with one role — deliberate, not drift:

- **`*Idle`** — state probes (`reactiveIdle`, `animationsIdle`, `commitIdle`, `surfaceIdle`): pure reads, positive polarity.
- **`Drain*`** — the mechanism (`drainToIdle`, `DrainSpec`, `DrainClause`, `DrainTimeoutError`): pumping toward idle.
- **`Settle*`** — the harness policy layer (`Settle`, `settleFixed`, `settleDrain`, `SettleFailure`, `HeadlessResult.settled`): how `runHeadless` uses the mechanism between events.

"Quiescence" survives in prose only; no type is named `Quiescence*` (round 2: three vocabularies collapsed to these families; the exception type takes the house `Error` suffix).

## Problem

`runHeadless` (both overloads, `src/fresco/headless/runner.nim`) advances the app by sleeping a fixed `perKeySettle` after each injected event. Downstreams must pick a settle long enough for the *slowest* async turn, which is slow (amoxtli's `test_run_headless` runs ~214 s across 222 call sites, dominated by these sleeps) and flaky (too-short settles capture state before a commit/repaint lands).

We replace the fixed sleep with a deterministic **drain to quiescence**: pump the chronos dispatcher until the app is genuinely idle, with a consumer-supplied `busy` predicate for async work the framework cannot see.

## Corrected async-surface model

What is actually in flight after a synthetic key press? The amoxtli request's model, corrected against the code:

1. **Reactive propagation is synchronous — including `gDeferred`, provably.** `drainQueue` (intonaco `scheduler.nim`) interleaves the height-ordered worklist *and* the deferred-action queue until both are empty, on the writer's stack. There is no `await` anywhere between `gPropagating = true` and `drainQueue`'s return, and `runAfterPropagation` called outside propagation runs its action synchronously — so `gQueue`/`gDeferred` can never be observed non-empty at any point control returns to the dispatcher. `reactiveIdle()` is therefore an **invariant, not a wait condition**; the drain asserts it loudly (a violation surfaces as a `dcReactive` timeout clause) so a future scheduler change that introduces an `await` on the drain path fails visibly instead of producing silently-wrong captures. *(Correction to the upstream request, which listed `gDeferred` as an async surface to wait on.)*
2. **The InlineScreen commit batcher** — the one `callSoon` in the codebase. Commits scrollback in bounded batches across dispatcher turns; `s.pendingCommit` / `s.commitInProgress` bracket the whole span including the `callSoon` re-arm gap (`pendingCommit` is set synchronously *before* the `callSoon`), so a predicate over them cannot false-positive mid-commit. Verified round 2: `driveCommitStep`/`finishCommit` contain no `await`, and `paint()` never touches the commit pipeline, so the paint postcondition cannot re-arm a commit.
3. **Layout dirtiness is a paint obligation, not in-flight async work.** Only `paint()`/`commit()` clears `r.pending`; in production that is `runAutoPaint`'s 33 ms timer — which the drain excludes by design. Waiting on dirty regions would therefore reintroduce a ≥33 ms floor per event (or hang outright when the test app never spawns `runAutoPaint`). The drain instead **paints as a postcondition** once the wait clauses settle (§Design 3), so captures are always fresh without waiting on any timer.
4. **Live animations** — `frameAnimations` (intonaco `animation.nim`) ticked by `clockLoop`. A live tween means "not settled"; the *bare* clock wakeup when no animations are live must not count as busy. Apps with deliberately perpetual animations (spinners) use `ignoreAnimations` (§Design 3) or stay on fixed settling.
5. **Timer loops** — `runAutoPaint` (33 ms) and the animation `clockLoop` never self-idle. The drain excludes their bare wakeups by construction: the predicate looks at application state, not dispatcher emptiness.
6. **App-level async the framework cannot see** — covered by the consumer-supplied `busy` hook; this is the crux of determinism for async-turn tests. Named canonical instances in this codebase, not just the ad hoc awaited daemon call from the upstream request:
   - an awaited network/daemon call inside a `receive:` turn (amoxtli's case — note its natural predicate is a **bare closure over existing `Future` refs** (`isReplBusy` checks `activeTurn`/`pendingAsks`), not a counter; `BusyGate` (§Design 4) is the convenience for sites *without* Future-shaped state to check);
   - **tasks spawned from the decide/act seam** — `runAfterPropagation`-hosted `spawn` is intonaco's *idiomatic* place for exactly this work, and a spawned `Mount`/`TaskGroup` future is invisible to every framework-side predicate for its entire flight (`busy = proc(): bool = not myMount.finished` is the pattern);
   - Supervisor restart-rate windows are a *time* window, not a pending future — tests exercising restart timing should stay on fixed settling (documented caveat, not a drain use case).
7. **Synthetic input delivery is itself an async surface — the round-2 critical.** `pushKey` is a synchronous `putNoWait`; delivery to the app's continuation then crosses **multiple chained dispatcher hops** (`AsyncQueue` getter wakeup → `popFirst` completion → `nextKey`'s `race()` completion → `nextKey`'s own future → app resumption; the `receive:` mailbox path adds the same shape again). Each hop is a `callSoon` that lands after the current poll's sentinel — ≥4 sequential `poll()` calls minimum, more for `receive:` apps. During that whole flight, **every other clause in §Design 3 is vacuously idle**. Resize events have no such chain (`setSize`/`applySizeNow` is fully synchronous). Closed by the `dcDispatcher` clause (§Delivery-gap decision).

**Visibility correction (drives the design):** `pendingCommit`, `commitInProgress`, and the pending-region scan are private to `inline_screen.nim`; Nim visibility is module-level, so `headless/runner.nim` cannot read them. Rather than exporting raw flags, `inline_screen.nim` exports two probes (§Design 2) — the deep-module cut: predicates out, flags hidden. *(Correction to the upstream request, which assumed no new fresco export was needed.)*

## Delivery-gap decision: `dcDispatcher` via chronos-fork introspection (resolved)

The stability window cannot close model §7: the window elapses in ~2 `poll()` calls while the delivery chain needs ≥4, and the hop count depends on app topology (`receive:` mailbox adds hops), so **no fixed window is sound**. Without a fix, a drain after `pushKey` returns before the app has dequeued the key — breaking exactly the per-key intermediate-state assertions (upstream Categories A–C) this RFC exists to make deterministic. (Final-state-only tests are masked by the harness's separate `appFut` wait, which is why the existing test suite would stay green — the bug would ship silently.)

**Decision: add `pendingCallbacksCount*(): int` to our chronos fork** — the ready-callback queue depth of the current dispatcher (sentinel excluded). `drainToIdle` gains a `dcDispatcher` clause: *no ready callbacks pending at check time*. This is the witness-chokepoint fix: every delivery hop **is** a ready callback, so the clause is exact for any app topology, with timers (auto-paint, clock, the drain's own deadline timer) naturally excluded because they live in the timer heap, not the callback queue. The accounting is clean at the check site: the drain's clause check runs inside its own resumed continuation, at which point its next pump is not yet scheduled and (without future-tracking) no destructor callbacks exist — so the count is zero exactly when no foreign work is ready. This supersedes the upstream request's "not a general chronos idle detector" non-goal, which rested on the now-disproven premise that the application-level predicate is exact.

**Upstream due diligence (the fork-forever question), checked 2026-08-06 against `status-im/nim-chronos`:**

- **Never proposed, never rejected.** No issue or PR proposes callback-queue introspection (searched: pending callbacks, idle, introspection, queue depth/length, `hasPendingOperations`, callSoon). There is no rejection to overrule.
- **Introspection is an accepted upstream category.** `stepsAsync`/`idleAsync`/tick callbacks exist explicitly "for more deterministic tests"; PR #85 (merged 2020) added dispatcher metrics including processed-callback counters; `-d:chronosFutureTracking` + `debugutils.pendingFuturesCount()` is *current* upstream API. (The #85 metrics were later culled in the v4 refactors while `chronosFutureTracking` survived — so the accessor should be pitched in the debugutils/deterministic-tests family, not the metrics family.)
- **No new permanent-fork commitment.** The fork is already load-bearing for `contextVar` (a non-negotiable; upstream PR pending) — the accessor is a ~10-line self-contained addition with trivial rebase cost, offered upstream alongside it.
- **Kept strictly separate from the contextvars PR.** The accessor lands on its own branch cut from `upstream/master` (`feat/pending-callbacks-count`), NOT on `feat/contextvars` — the two are independent upstream-PR units and neither's review may be entangled with the other's. Consumers need both, so the fork gains an integration branch (`fresco-pin` = merge of `feat/contextvars` + `feat/pending-callbacks-count`); the chronos ref in the milpa manifests (declared in intonaco, locked transitively by fresco/amoxtli — currently `ref "feat/contextvars"`) moves to the integration branch. Either PR merging upstream just shrinks the integration merge; the branches never cross-contaminate.
- **A no-fork fallback exists, so we can never be fork-locked on this feature:** upstream-standard `-d:chronosFutureTracking` tracks completed futures until their callbacks are processed (`futureDestructor` runs one hop after the callbacks), so `pendingFuturesCount` over the finished states is a conservative dispatcher-quiet witness with **no fork change**. It is deliberately *not* the primary design: the destructor lag and the drain's own pump future make the accounting delicate (self-noise: the check always sees its own just-completed `stepsAsync` future), where the fork accessor's is exact. If the fork ever had to drop the accessor, a spike validating that accounting swaps in behind the same `dcDispatcher` clause.

## Design

### 1. intonaco: read-only idle accessors

Exported where the state lives; useful beyond testing (observability; sinopia would build its own drain from these — it cannot reuse fresco's, see §Scope):

```nim
# intonaco/src/intonaco/reactive/primitives/scheduler.nim
proc reactivePendingCount*(): int = gQueue.len + gDeferred.len
proc reactiveIdle*(): bool =
  not gPropagating and gQueue.len == 0 and gDeferred.len == 0

# intonaco/src/intonaco/reactive/dsl/animation.nim
proc animationsIdle*(): bool = frameAnimations.len == 0
```

`animationsIdle` (not `animationsPending`) keeps uniform positive-idle polarity with `reactiveIdle`/`surfaceIdle`, so every consumer conjunction is a flat AND with no hand negation. *(Correction to the upstream request, which proposed `animationsPending`.)* Both surface through the public `import intonaco/reactive` (verified round 2: `reactive.nim` → `reactive_internal` re-export chain `include`s both files, so `*`-marked procs surface as claimed); tests are black-box. The walker does not reject bare `reactiveIdle()` calls inside effect bodies (verified against `passes_core.nim`: no inferable tags, direct `nskProc` call), so the A1 mid-propagation test needs no escape hatch. Per intonaco convention, deferrals/decisions for these land inline in this RFC (intonaco tracks no GH issues).

### 2. fresco: `anyPending` consolidation + InlineScreen probes

`inline_screen.nim`'s `anyPendingLayout` and `screen.nim`'s `anyPending` are byte-identical private copies. This RFC consolidates them where the state lives — `render/layout.nim` exports `anyPending*(l: Layout): bool` — before adding a third caller would lock the duplication in.

```nim
# src/fresco/inline_screen.nim
proc commitIdle*[S: Sink](s: InlineScreen[S]): bool =
  ## True iff no commit batch is pending or in progress.
  not s.pendingCommit and not s.commitInProgress

proc surfaceIdle*[S: Sink](s: InlineScreen[S]): bool =
  ## True iff the render surface has no work in flight and no unpainted
  ## dirty regions. Production-safe read-only probe (observability).
  s.commitIdle and not anyPending(s.layout)
```

Two probes, generic over `Sink`, flags stay private. `drainToIdle` waits on `commitIdle` (the async part) and *enforces* full `surfaceIdle` via its paint postcondition; keeping the probes separate also gives the timeout diagnostics commit-vs-layout resolution.

**H2 resolution (round-1 stage-4 code review, 2026-08-07).** `BandNotBottomAnchoredDefect` — raised deep inside the async commit driver (`driveCommitStep`, invoked from a `callSoon` callback with no `Defect` handler upstream in chronos's `poll()`) — used to escape straight into the dispatcher and kill the process on whatever turn happened to run it, possibly during an unrelated later test. Fix: `driveCommitStep` catches `Defect` around `commitOneBatch`, stores it on a new private `pendingDefect: ref Defect` field on `InlineScreen`, and finishes the burst cleanly instead of letting it propagate. `reraisePendingDefect` re-raises (and clears) it synchronously at every relevant public entry point that touches the commit machinery — `paint`, the `LogSink.append`/`appendLine`/`bindScrollback` notify closure, `teardownFlush`, and `commit` — so the Defect always surfaces attributably inside the discovering caller's own `waitFor`, never the dispatcher's.

**R2-M1 addendum (round-2 stage-4 code review, 2026-08-07).** The re-raise used to be `teardownFlush`'s FIRST statement, which voided its own "zero bytes dropped" drain guarantee exactly when a Defect was pending (tail lines buffered since the capture were never drained) and, inside `withInlineScreenImpl`'s `finally` (`inline_teardown.nim`), skipped the REST of that finally (watch-task cancel, self-pipe unregister, graceful/tail disarm) — cleanup debt for real `TerminalSink` sessions. Fixed by moving the re-raise to `teardownFlush`'s LAST statement (drain and disarm always complete first) and by having `withInlineScreenImpl`'s `finally` catch the re-raised Defect, run its own remaining cleanup unconditionally, and only then re-raise. In `runHeadless` (§5), a captured Defect now supersedes result reporting by construction: the re-raise fires at whichever blessed entry point next runs post-capture — guaranteed `teardownFlush` under `settleFixed`; typically an earlier `drainToIdle`'s internal `paint()` under `settleDrain` (R3-5, round-3 stage-4: corrected — `drainToIdle`'s own postcondition calls `screen.paint()` unconditionally once every clause reads idle, and that `paint()` re-raises before `teardownFlush` is ever reached; the surrounding `try/except DrainTimeoutError` in `runHeadless`'s `skDrain` loop does not catch a bare `Defect`, so it propagates straight out) — either way strictly before `HeadlessResult`'s fields are populated, so §5's "both recorded" guarantee for `appError`/`sfScriptTruncated` holds only absent a captured Defect — a compound failure (app crash + captured Defect) surfaces as a raised Defect out of `runHeadless`, not a `HeadlessResult`, since a Defect signals a programming error the run's results can't speak to. Accepted residual, unchanged by this round: a screen dropped after a Defect capture with no further call to any of the blessed entry points silently loses the stored Defect — inherent to deferred capture.

**R3-2 addendum (round-3 stage-4 code review, 2026-08-07).** The doctrine above (H2 → R2-M1) governs the exception/cancellation teardown path inside `withInlineScreenImpl`'s `finally`; the OS-signal graceful-teardown path (`watchTeardownSignals`, `inline_teardown.nim`) had the same hole. It used to call `teardownFlush(s)` with no guard at all, then `restoreAllAndReraise` — since R2-M1 made `teardownFlush` able to re-raise a pending Defect as its LAST statement, and chronos's async-macro Defect handler (`asyncmacro.nim`'s `addDefect`) re-raises a caught Defect EAGERLY right where it's caught rather than storing it on the future, the unguarded call let that raise fly straight past `restoreAllAndReraise` on the FIRST graceful SIGTERM/SIGINT — tier-2 termios restore was skipped, saved only by a second signal hitting the hard handler's own restore. Fixed by splitting `restoreAllAndReraise` (`termios.nim`) into `restoreAll` (tail flush, alt-screen leave, termios stack restore, graceful disarm) and `reraiseSignal` (the final `kill(getpid(), sig)`), and extracting `completeGracefulTeardown` (`inline_teardown.nim`) to apply the identical capture-cleanup-then-surface precedence doctrine as `withInlineScreenImpl`'s `finally`: catch `teardownFlush`'s Defect, ALWAYS call `restoreAll()`, then either raise the captured Defect (superseding the signal) or call `reraiseSignal(sig)`. Restore always precedes both the disarm and whichever exception ultimately wins — the OS-signal path now honors the same doctrine as the exception/cancellation path documented above. (Round-4 stage-4 code review added a runtime ordering guard — a `restoreAllCompleted` threadvar `doAssert`'d by `reraiseSignal` — enforcing that `restoreAll` ran first; round 5 superseded it with a structural fix: `restoreAll`/`reraiseSignal` demoted to module-private and collapsed into one exported composition, `finishGracefulTeardown`, so the ordering is unrepresentable-otherwise rather than runtime-checked.)

**R3-3 addendum (round-3 stage-4 code review, 2026-08-07).** `withInlineScreenImpl`'s `finally` re-raising a captured Defect (R2-M1, above) has a compound-failure case worth naming explicitly: if `body` was cancelled, the `finally` runs with a `CancelledError` already in flight, and the `raise pendingTeardownDefect` at the end of the finally executes mid-unwind — Nim's raise-during-unwind semantics mean that new raise REPLACES the in-flight `CancelledError`, so the caller observes the Defect and chronos's cancellation propagation for that task is, in this one compound scenario, a casualty of it. This is deliberate, not an oversight: it is the same precedence doctrine applied everywhere else in the teardown machinery (cleanup always completes first; a captured Defect, when present, wins the final outcome), extended to cancellation because a Defect signals a programming error more severe than an in-flight cancellation request. Residual, accepted: a caller relying on `CancelledError` specifically propagating out of a `withInlineScreen` scope (e.g. to distinguish "cancelled" from "crashed" in its own cleanup) cannot do so when a Defect happens to be pending at the same moment — inherent to the precedence choice, not fixed by this round.

### 3. fresco: `drainToIdle` in the headless module

```nim
# src/fresco/headless/runner.nim
type
  DrainClause* = enum
    dcReactive, dcAnimations, dcCommit, dcDispatcher, dcBusy
  DrainTimeoutError* = object of AsyncTimeoutError
    failingClauses*: set[DrainClause]
    busyLabels*: seq[string]      # M5 (round-1 stage-4): labels of the
                                   # `DrainSpec.gates` isBusy() at raise
                                   # time; @[] when dcBusy was driven only
                                   # by `busy` (opaque closure, unnameable).
                                   # R2-M3: enforced correlation — non-empty
                                   # implies dcBusy in failingClauses.
  DrainSpec* = object
    busy*: BusyPredicate          # see §4 (busy module)
    gates*: seq[BusyGate]         # M5: additional gates ORed into dcBusy;
                                   # nameable in busyLabels on timeout
    drainTimeout*: Duration
    ignoreAnimations*: bool

proc drainToIdle*(screen: InlineScreen[MemorySink];
                  spec: DrainSpec): Future[void] {.async.} =
  ## Pump the dispatcher until the app is quiescent, then paint.
  ## Wait clauses (all must hold, stably):
  ##   reactiveIdle()             # invariant assertion (model §1)
  ##   animationsIdle()           # unless spec.ignoreAnimations
  ##   screen.commitIdle()        # commit batcher settled
  ##   dispatcher quiet           # no ready callbacks (model §7)
  ##   spec.busy settled          # consumer async settled (nil = no clause)
  ## Postcondition: screen.paint() — clears dirty regions so
  ## surfaceIdle() holds on return without waiting on the 33 ms
  ## auto-paint timer. Raises DrainTimeoutError (with failingClauses)
  ## at the deadline.

proc drainToIdle*(screen: InlineScreen[MemorySink];
                  busy: BusyPredicate = nil;
                  drainTimeout = 1.seconds;
                  ignoreAnimations = false;
                  gates: seq[BusyGate] = @[]): Future[void] =
  ## Convenience overload; forwards a DrainSpec. `gates` (M5) trails as a
  ## defaulted param so existing call sites keep compiling unchanged.
```

`DrainSpec` is the *same object* `Settle.skDrain` carries (§5) — the drain's parameters and the harness's drain-mode payload cannot drift because they are one declaration (round 2: the three loose parameters duplicated `skDrain`'s fields; unified).

**Pump & liveness.** `await stepsAsync(1)` — chronos's purpose-built "suspend for N `poll()` calls" primitive (its docstring: for "more deterministic tests"), rather than the informal `sleepAsync(0)` yield idiom. Note the true cost: a resumed coroutine routes through `finish()` → `callSoon`, which lands after the current poll's sentinel, so one pump ≈ **2 `poll()` calls** end to end (verified round 2 against the fork's engine). **Stage-3 finding (standalone chronos-only repro):** `stepsAsync` continuations ride the dispatcher's *tick* queue, which does not bound `poll()`'s `select()` timeout — ticks drain only *after* `select()` returns, and the timeout is computed from timers/callbacks/idlers alone. A pump on an otherwise-dormant dispatcher therefore blocks until the next real event, indefinitely if none exists (exactly the stuck-`busy` case). Deadline liveness comes from a real timer: `drainToIdle` arms `sleepAsync(spec.drainTimeout)` once at entry, cancelled on every exit path. Its presence in the timer heap bounds every `select()` to the deadline; any real dispatcher activity wakes `poll()` and the pending pump tick drains that same iteration, so wake-on-activity latency is one iteration and a dormant wait costs zero CPU. The timer future is also the **deadline truth**: the machine never reads `Moment.now()` — it raises iff the timer future has finished *and* the just-evaluated clause set is non-empty, so the wake mechanism and the deadline predicate are the same object and cannot diverge. (This is deliberately *not* a chronos fork patch, and — established post-stage-3 by upstream archaeology — not a workaround either: chronos PR #445 (2023-09) *deliberately* moved `stepsAsync` continuations onto a separate tick queue that never wakes the dispatcher, fixing its own `stepsAsync` test in the same commit by arming a `sleepAsync` before each `poll()` ("We need `fut` because `stepsAsync` do not power `poll()` anymore", `tests/testtime.nim`). Timer-plus-pump is therefore the *canonical* upstream idiom, which this machine independently re-derived — with the timer additionally serving as deadline truth. The no-self-wake property is also exactly what makes `stepsAsync` the right pump: the self-live alternatives (`sleepAsync(0)`, `idleAsync`) bound every `select()` to zero and busy-spin, while a queued tick lets a dormant wait sleep at zero CPU. Verified at upstream master `b71392a`. No upstream filing: the semantic is intended and their test documents the idiom; the only upstream gap is a missing docstring sentence, judged not worth pursuing.)

**Accepted risk: `pendingCallbacksCount` ticks-invisibility (M2, round-1 stage-4, resolved).** `pendingCallbacksCount` reads `loop.callbacks` (the ready-callback queue) exactly, but chronos has a third queue, `loop.ticks` — the home of `stepsAsync` chaining, `idleAsync`, and `cancelSoon`'s `checktick` retry — which `processTicks()` migrates into `loop.callbacks` once, near the top of each `poll()`, *before* that poll's callback batch runs; a tick enqueued during that same batch is invisible to the accessor until the *next* `poll()`. No shipped fresco path is affected: the review round-1 seam trace confirmed the entire key-delivery chain (`pushKey` → `AsyncQueue` wakeup → `nextKey`'s `race()` → app resumption) rides `callSoon`/`loop.callbacks` throughout, never `loop.ticks`. The implication is `drainToIdle`'s single idle read (§ above, "why there is no stability window") would not self-heal a false idle if `dcDispatcher` read zero while a tick was queued-but-unmigrated. A future consumer whose app drives cancellation via `cancelSoon` from inside an async turn (rather than delivery-chain `callSoon` work) must not rely on `dcDispatcher` alone to witness that state — it needs its own `DrainSpec.busy`/`gates` clause covering it, the same way any framework-invisible async surface (§Corrected async-surface model) already requires one.

**State machine — single-read, one clause evaluation per iteration, deadline gates only re-pumping:**

```nim
let deadlineFut = sleepAsync(spec.drainTimeout)  # liveness + deadline truth (one object)
defer:
  if not deadlineFut.finished: deadlineFut.cancelSoon()
while true:
  let failing = failingClauses(screen, spec)  # ONE evaluation, reused below
  if failing == {}: break                     # single idle read is sound (dcDispatcher is exact)
  if deadlineFut.finished:
    let stuckLabels =                                        # M5, gated R2-M3
      if dcBusy in failing: spec.gates.filterIt(it.isBusy()).mapIt(it.label())
      else: @[]
    var msg = "drain timeout; failing clauses: " & $failing
    if stuckLabels.len > 0: msg &= "; busy gates: " & stuckLabels.join(", ")
    var e = newException(DrainTimeoutError, msg)
    e.failingClauses = failing
    e.busyLabels = stuckLabels
    raise e
  await stepsAsync(1)  # event-driven: sleeps in select() until activity or the deadline timer
screen.paint()
```

Fixes baked into this shape (rounds 2–3):

- **Deadline never fires before an idle read.** The check sits *after* the clause evaluation, and an idle read breaks unconditionally — so a microscopic `drainTimeout` on an already-idle app succeeds instead of spuriously raising, and `failingClauses` can never be the empty set on a raise.
- **`failingClauses(screen, spec)` has a written contract:** it evaluates each clause exactly once per iteration into a `set[DrainClause]` (idle ⇔ empty set), and the raise reuses *that same set* — the reported clauses are exactly the ones that failed the final check, with no re-evaluation divergence. A clause disabled by `spec.ignoreAnimations` (or `busy == nil`) is never evaluated and never appears in the set.
- **Exception construction:** `newException` + field assignment (the house idiom — no in-repo exception is raised via object-construction syntax, which would not compile for a non-ref exception type anyway), with `msg` populated so `getCurrentExceptionMsg()` is never empty.

**Why there is no stability window or backoff (stage-3 redesign, approved 2026-08-06).** Round 2's machine carried `StabilityWindow = 2` as "cheap insurance" and a `BackoffAfter` slowdown to `sleepAsync(1.milliseconds)`. Both rested on the assumption that `stepsAsync(1)` pumps complete promptly while the process is dormant — i.e. that a busy wait *spins*. It doesn't (see Pump & liveness): a dormant wait sleeps in `select()` at zero CPU, so there is nothing to back off from — backoff would only add 1 ms polling and reduce responsiveness — and it could never have engaged from dormancy anyway (it required 10 *completed* pumps; a dormant dispatcher never completes the first). The window fails harder under the event-driven pump: a "confirm idle" pump on an already-idle screen blocks until the *deadline*, turning every trivially-idle drain into a full-`drainTimeout` stall. Its insurance role is also gone: with `dcDispatcher` the clause set is an exact witness for framework-visible work — if all clauses read idle, nothing outside the deliberately-excluded timer heap can be in flight, so a second read confirms nothing the first didn't. A single idle read is sound, and is the design. The loop holds no counters at all; sequential drains share nothing; two drains *concurrently* in flight are safe by construction (all shared reads are read-only probes; a double `paint()` is idempotent) though not a designed-for pattern.

**Cancellation contract:** a `CancelledError` raised into the pump loop (e.g. an outer test wraps `runHeadless` in its own `withTimeout`) propagates out *without* painting — no half-drained postcondition; the caller inherits whatever surface state existed at cancellation, exactly like the existing `appFut` cancel path. `drainToIdle` owns no gate or shared state, so nothing leaks; a consumer's `withBusy` block remains exception-safe through its own `finally`.

**`BusyPredicate` contract (compile-time enforced, F2 follow-up 2026-08-07):** must be O(1)-cheap (called every iteration) and **context-free** — reading plain fields, counters, or `Future.finished` state (amoxtli's `isReplBusy` shape), never scope-dependent reactive reads. It runs under the *harness's* ambient context, not the app's turn-local (possibly speculative) scope, so a reactive read could observe base values while the app's overlay still has work in flight — a silent false-idle. Round 2 accepted this as "no mechanical enforcement possible"; that premise was refuted by a spike: intonaco's `Signal.get`/`Dynamic.get` carry `ReactiveRead`, and `Signal.setRaw` carries `ReactiveWrite`, as genuine Nim `tags` effects (`reactive/primitives/subscribable.nim`, `signal.nim`), not just walker-level analysis — so `BusyPredicate* = proc(): bool {.gcsafe, raises: [], forbids: [ReactiveRead, ReactiveWrite].}` rejects a reactive-reading closure at the assignment/conversion site with a compiler error (`type mismatch: ... .notTag catched an illegal effect`), while plain-field, `Future.finished`, and `BusyGate.predicate()`/`toPredicate` closures convert cleanly (proven in `tests/unit/test_busy_gate.nim`). One honest limit: `forbids` sees only what the Nim effect system can infer through the call graph — a body that wraps a reactive read in `{.cast(tags: []).}:` (the same escape hatch intonaco's own `setCore` uses internally to firewall journaling effects) launders the tag and compiles anyway. That is a deliberate, visible unsafe-cast at the call site, not a silent gap; the structural steer (`BusyGate`/`Future`-shaped closures, no incentive to read reactive state in a busy check) remains the primary defense.

### 4. fresco: `busy` module — ship the counter, not just the signature

`BusyGate` is **not** headless-gated — it is a general-purpose busy tracker (a production `TerminalSink` app has the same use for a "syncing…" indicator), so it lives in its own module, not `headless/runner.nim` (round 2: homing it in a testing module sent a false test-only signal; §Scope's type-gate argument never applied to it). `headless/runner.nim` imports and re-exports it.

```nim
# src/fresco/busy.nim
import intonaco/reactive

type
  BusyPredicate* = proc(): bool {.gcsafe, raises: [],
                                  forbids: [ReactiveRead, ReactiveWrite].}
  BusyGate* = ref object
    labelStr: string
    count: int

proc newBusyGate*(label = ""): BusyGate = BusyGate(labelStr: label)
proc label*(g: BusyGate): string = g.labelStr
proc isBusy*(g: BusyGate): bool {.inline.} = g.count > 0
proc predicate*(g: BusyGate): BusyPredicate =
  (proc(): bool {.gcsafe, raises: [].} = g.isBusy())
converter toPredicate*(g: BusyGate): BusyPredicate = g.predicate()

# begin/finish are module-PRIVATE: only withBusy can move the counter, so
# an unmatched dec (silent negative count masking real busyness) is
# unrepresentable, not merely discouraged. Precedent: LogSink exposes
# `append` and nothing else; the termios depth counter is likewise sealed.
proc begin(g: BusyGate) {.inline.} = inc g.count
proc finish(g: BusyGate) {.inline.} = dec g.count

template withBusy*(g: BusyGate, body: untyped) =
  g.begin()
  try: body
  finally: g.finish()

proc anyBusy*(gates: varargs[BusyGate]): BusyPredicate =
  ## M5 (round-1 stage-4): a single predicate true iff ANY of `gates` is
  ## busy. Materializes `gates` into a `seq` at construction time — the
  ## returned closure captures that seq, never the `varargs`-backed
  ## `openArray`, which is only valid for the call's duration.
  let gs = @gates
  result = proc(): bool {.gcsafe, raises: [].} =
    for g in gs:
      if g.isBusy(): return true
    false
```

Consumer pattern: `withBusy(gate): await state.callDaemon()` at each instrumented await point — leak-proof by construction, and the counter (vs a boolean) is correct under overlapping turns. The `converter` lets call sites write `settleDrain(busy = gate)` directly (precedent: the `Subscribable` converter in `reactive/binding.nim`). Every named use case is block-scoped; if a non-lexical span (begin at send, finish at response) ever materializes, re-exporting `begin`/`finish` with a `doAssert g.count > 0` guard is a one-line reversal — the hole is not shipped speculatively.

**M5 resolution (round-1 stage-4 code review, 2026-08-07).** `label` shipped in the original design but was diagnostically inert: a `dcBusy` timeout recorded only the enum tag, never *which* gate was stuck, and `DrainSpec.busy` accepted only one closure, forcing multi-gate consumers to hand-roll `proc(): bool = g1.isBusy() or g2.isBusy()` and then manually re-probe each gate after a timeout to find the culprit. Three additions close the loop, all additive and source-compatible:

- `anyBusy(gates: varargs[BusyGate]): BusyPredicate` (above) — the combinator consumers previously hand-rolled, for the case where a single closure is still what's wanted (e.g. assigning `DrainSpec.busy` directly).
- `DrainSpec.gates*: seq[BusyGate]` (§3) — a second, structural path into the same `dcBusy` clause: `dcBusy` fails iff `(busy != nil and busy()) or` any gate in `gates` is busy, a plain OR with no invalid combination (both fields may be set at once). Unlike a gate folded into `busy` by hand or via `anyBusy`, a gate listed in `gates` stays *nameable* on timeout — a `BusyPredicate` closure is opaque past the call boundary, so `busy` alone can never be introspected this way regardless of what it wraps.
- `DrainTimeoutError.busyLabels*: seq[string]` (§3) / `SettleFailure.busyLabels*: seq[string]` (§5) — populated at raise time with the labels of the `gates` members that were `isBusy()` at that instant, and included in `DrainTimeoutError.msg` (e.g. `"...; busy gates: repl, decider"`) so the default `unittest` failure output names the stuck gate with zero consumer effort. `SettleFailure.busyLabels` mirrors `clauses`'s existing raise-to-report survival (same `DrainTimeoutError` → `SettleFailure` capture sites in §5's event loop), so a `settleDrain` consumer sees the stuck gate's name without re-probing its own gates after the fact.

The asymmetry is inherent, not a bug: `busyLabels` is always `@[]` when a `dcBusy` timeout was driven purely by `spec.busy` (no `gates` set) — an opaque closure has nothing to name. `gates` is the diagnosable path; a closure assigned to `busy` (hand-rolled or via `anyBusy`) trades that diagnosability for flexibility, same as before this fix. Tests: `tests/unit/test_busy_gate.nim` (`anyBusy` combinator), `tests/unit/test_drain_to_idle.nim` (multi-gate `busyLabels` at the `DrainTimeoutError` level, `busy`+`gates` OR composition, closure-only asymmetry), `tests/unit/test_settle_drain.nim` (`busyLabels` surviving into a settle-mode `SettleFailure`).

**R2-M3 addendum (round-2 stage-4 code review, 2026-08-07).** `stuckLabels` in the state machine above (§3) used to be computed unconditionally from `spec.gates`, correlated with `dcBusy in failingClauses` only by convention — nothing stopped a future edit (e.g. caching `stuckLabels` from an earlier iteration, or moving the message construction) from letting a timeout caused solely by another clause report "busy gates: ..." and imply false causation. Fixed by gating the computation itself on `dcBusy in failing`, making the invariant real at the (single) raise site instead of relying on the synchronous, no-intervening-`await` shape of the loop to keep the two consistent. `DrainTimeoutError.busyLabels`/`SettleFailure.busyLabels` now document the enforced correlation directly. Test: `tests/unit/test_drain_to_idle.nim`, "R2-M3" suite — a `dcCommit`-only timeout (forced via the `frescoTesting` `setCommitInProgressForTest` seam, not `dcBusy`) with an unrelated `BusyGate` held busy outside `spec.gates` asserts `busyLabels == @[]` and `"busy gates"` absent from `.msg`.

### 5. fresco: drain-settling `runHeadless`

Settle is a **discriminated union**, mirroring `InlineEvent` two types up in the same file — the invalid combinations (`busy` under fixed settling, `perKeySettle` under drain) become unrepresentable instead of silently ignored, on-thesis for compile-time-first. Its drain payload *is* `DrainSpec` (§3), so harness and primitive share one parameter declaration.

```nim
type
  SettleKind* = enum skFixed, skDrain
  Settle* = object
    case kind*: SettleKind
    of skFixed:
      perKeySettle*: Duration
    of skDrain:
      drain*: DrainSpec

proc settleFixed*(perKeySettle = 1.milliseconds): Settle
proc settleDrain*(busy: BusyPredicate = nil,
                  drainTimeout = 1.seconds,
                  ignoreAnimations = false,
                  gates: seq[BusyGate] = @[]): Settle   # gates: M5, trailing default

proc runHeadless*(screen: InlineScreen[MemorySink],
                  app: HeadlessInlineApp,
                  events: seq[InlineEvent] = @[],
                  timeout: Duration = 1.seconds,
                  settle: Settle = settleFixed()
                 ): Future[HeadlessResult]
```

`timeout` keeps its existing single meaning — the trailing `appFut` wait. `drainTimeout` bounds each drain. Drain mode additionally bounds the post-cancel wait (round 2: the existing overloads' bare `try: await appFut` after `cancelSoon()` is unbounded — this codebase's own record on `race()` non-propagating cancellation makes that tail real): `const CancelGrace = 100.milliseconds`; a future still unfinished after the grace is abandoned and the capture proceeds. Worst-case wall clock under drain is then genuinely bounded: `events.len × drainTimeout + timeout + CancelGrace + drainTimeout`; the expected case is the compute floor, since each drain returns as soon as its clauses settle.

**F1 correction (2026-08-07): `withTimeout` cannot implement the bound above.** The original slice-12 wording (`discard await appFut.withTimeout(CancelGrace)`) assumed `withTimeout` behaves like a plain "wait up to N, then give up." It does not: on timeout it calls `.cancelSoon()` on the wrapped future, but its own returned future resolves *only once the wrapped future actually finishes* (`chronos/internal/asyncfutures.nim`, `withTimeout`'s `continuation` — registered both as the timer callback and via `fut.addCallback`; the timeout branch cancels and returns without completing `retFuture`, so `retFuture` only settles on the *later* callback fired by `fut` itself finishing). For an app future engineered to survive cancellation — it catches `CancelledError` and re-awaits, or wraps its await in `noCancel` — `fut` never finishes, so `withTimeout` never returns: the harness hung at the very first `withTimeout` call (`timeout`, not even reaching `CancelGrace`), not at the grace. Reproduced directly: a catch-and-loop app under the pre-fix harness hangs the test binary indefinitely (one run logged 2.77M cancellation retries in 45s with no forward progress) rather than returning a `HeadlessResult` with `appFut` abandoned.

This is not fixable by tuning durations — it is a structural mismatch between `withTimeout`'s completion contract and an adversarial-but-legitimate app shape. Cancellation-survival also cannot be witnessed in bounded time by any polling scheme: nothing distinguishes "about to land" from "never lands" from the outside, and chronos's own cancellation retry (`cancelSoon`'s `checktick`) spins on every dispatcher tick in the adversarial case, so waiting for the dispatcher to go quiescent never obtains either. The grace is therefore a forced wall-clock deadline, epistemically the same kind of fact as `drainTimeout` (§3) — not a derived one.

**The fix: race a plain timer instead of trusting `withTimeout`'s completion contract.** `race(fut0, futs...)` (`chronos/internal/asyncfutures.nim`) resolves the instant *either* argument finishes, in *any* terminal state (completed, failed, or cancelled — its internal `addCallback` fires on any finish transition, unconditionally), and never touches the loser (`## On cancel futures in ``futs`` WILL NOT BE cancelled.`). Racing `appFut` against a bare `sleepAsync(timeout)` therefore genuinely bounds the wait regardless of whether `appFut` cooperates. The one hazard is symmetric with `race()`'s own documented behavior: never cancel the `race()` future itself (its cancellation does not propagate to the children — the same non-propagation this codebase already had to account for), so `race()` is always awaited to completion; the *loser* (whichever of `appFut`/timer didn't finish) is cancelled by hand afterward so the timer heap stays clean. This is now the shared teardown for **both** `runHeadless` overloads — see below.

**Totality supersedes the round-2 "fixed path stays unbounded" note.** That note assumed the fixed path's bare `await appFut` was an acceptable deliberate difference from drain mode's bounded wait; the `withTimeout` finding disproves the premise (an unbounded wait on a cancellation-surviving app hangs the *fixed* path exactly as it hung drain mode — there is no settle-mode reason for one path to hang and the other not to). Totality — every path returns a `HeadlessResult`, always — is a harness invariant, not a per-settle-mode policy. Both overloads now share one `teardownAppFut` routine implementing the race-based wait/cancel/grace/abandon sequence; `withTimeout` is gone from `runner.nim` entirely.

**Residual, documented, not fork-patched:** after `teardownAppFut` abandons a catch-and-loop app, chronos's cancellation retry (`cancelSoon`'s `checktick`) keeps spinning — retrying `tryCancel` on the orphaned future every dispatcher tick — until process exit, since nothing ever calls it again to stop. This is inert (the harness has already returned; nothing awaits the orphaned future) but not free, and not something this RFC fork-patches: fork minimalism (`docs/rfc-chronos-contextvars.md`'s standing bar) — a process-lifetime background retry on an abandoned adversarial test double is not worth carrying upstream drift for.

**Accumulation across calls (M12, round-1 stage-4 code review):** the note above describes the per-abandonment mechanism, but each abandoned `appFut` adds its own independent per-tick retry — the cost is not one background spin, it is one *more* background spin per abandonment, and nothing ever removes an entry once added. A test binary that exercises the timeout path across many `runHeadless` calls (a suite with several cancellation-survival or hung-app tests, for instance) therefore accumulates these retries monotonically for the remainder of that process's life, not just for the one test that triggered abandonment. This is still accepted as a documented cost rather than fixed: each retry is O(1) and inert, the accumulation is bounded by the number of *abandoning* `runHeadless` calls in a process (not, e.g., by wall-clock time or event volume), and a real test suite's abandonment count is small relative to its total runtime. It remains out of scope for a fork patch for the same fork-minimalism reason as the single-instance case.

**Failure semantics — the primitive raises, the harness reports.** Both existing overloads document "the test still gets a `HeadlessResult` with the state at cancellation"; drain mode preserves that always-returns-a-result contract:

```nim
type
  SettleFailureSite* = enum sfEvent, sfFinalDrain, sfScriptTruncated
  SettleFailure* = object
    clauses*: set[DrainClause]
    busyLabels*: seq[string]      # M5: mirrors clauses, sourced from the
                                   # captured DrainTimeoutError.busyLabels
    case site*: SettleFailureSite
    of sfEvent: eventIndex*: int   # index into `events`
    of sfFinalDrain: discard
    of sfScriptTruncated: firstUndeliveredIndex*: int  # index into `events`

  HeadlessResult* = object
    rows*: seq[string]
    committedRows*: seq[string]
    appError*: ref Exception       # nil unless the app future failed
    settleFailures*: seq[SettleFailure]  # empty = fully quiescent run
    cancelGraceExpired*: bool      # true iff CancelGrace elapsed with appFut still pending

proc settled*(r: HeadlessResult): bool =
  ## True iff the run hit no drain timeout, the app raised nothing, and
  ## the post-cancel grace never expired on a still-live app future — the
  ## one-expression "clean run" assertion.
  r.appError.isNil and r.settleFailures.len == 0 and not r.cancelGraceExpired
```

(Round 2: `eventIndex = -1` as a final-drain sentinel was the exact silently-encoded invalid state §5's own union argument rejects — now a discriminated union, exhaustively matchable. `appError` is `ref Exception`, deliberately as wide as the `{.raises: [Exception]}` app proc type it captures. Field additions are source-compatible: no existing test or amoxtli site constructs `HeadlessResult` positionally — verified.)

**H1 (round-1 stage-4 code review, 2026-08-07 — Corey-approved spec change).** The `sfScriptTruncated` site above was not part of the original B11 design; it closes a gap the round-1 review found in the design itself, not just the implementation. As originally specified, a *successful* early app exit (`appFut.finished` and not failed) hit the app-death short-circuit and stopped injecting, but recorded nothing: `appError` stayed nil (no failure occurred), `settleFailures` stayed empty (no drain timed out), so `settled()` read `true` over a script that only partly ran — a silent truncation, exactly the class of fact this RFC's "primitive raises, harness reports" thesis exists to surface. `skFixed` was worse: it had no short-circuit at all, so it kept pushing scripted events into a dead app's queue. `settled()` itself needs no change — `settleFailures.len == 0` already folds in any newly-recorded truncation. `appError` and `sfScriptTruncated` are orthogonal facts, both recorded when both are true: a mid-script crash still populates `appError` as before, and now ALSO records the truncation, since "the app failed" and "the script didn't finish" are each true independently of the other.

`cancelGraceExpired` (F1, 2026-08-07) closes the one failure state B11 left unrepresentable: if the post-cancel grace also expires — the app's cancellation path is hung or broken — the pre-F1 harness returned with `appFut` still pending and no signal (`appError` stays nil, since chronos's `Failed`/`Cancelled` states are disjoint and an abandoned-pending future is neither; `settleFailures` stays empty; `settled()` read `true` over a live orphaned future). Populated by the shared `teardownAppFut` routine described below for **both** overloads — see the `withTimeout` correction above for why this could not be built on `withTimeout`.

Event loop, per event, **shared by both settle kinds** (H1: pre-H1 only `skDrain` had a short-circuit at all, and even there it recorded nothing on a successful early exit):
- **App-death short-circuit:** if `appFut.finished` before injection — successfully or with an error — stop injecting and record `SettleFailure(site: sfScriptTruncated, firstUndeliveredIndex: <this event's index>)`. `appError` (populated separately, on failure, by the shared post-script teardown below) is a distinct fact recorded independently — a crash and a truncated script are both true at once, and both are recorded when both occur.
- (drain mode only) Inject, then `drainToIdle(screen, settle.drain)`; on `DrainTimeoutError`, record a `SettleFailure(site: sfEvent, ...)` and short-circuit remaining events. (fixed mode) Inject, then `sleepAsync(settle.perKeySettle)` — unchanged.
- After the app-finish/cancel dance, one final **best-effort** drain in drain mode only (its timeout records `site = sfFinalDrain`, never raises out), then `teardownFlush()` + `paint()` + capture, unconditionally — exactly as today.

A stuck `busy` from a crashed turn that skipped its `finally` (i.e. not using `withBusy`) surfaces as a `dcBusy` settle failure — diagnosable, not silent. When the stuck gate was reachable via `DrainSpec.gates` (§3, M5), the failure additionally names it: `SettleFailure.busyLabels` carries the gate's `label`, sourced from the underlying `DrainTimeoutError.busyLabels`.

The plain Layout-based overload keeps fixed-sleep only; see §Out of scope.

**Default:** `settleFixed()` remains the default for now — a deliberate, recorded decision, not drift: flipping the default to drain is revisited after amoxtli's migration proves the drain path across its wrapper layer (222 call sites funnel through ~4 local wrapper signatures — the wrappers, not the sites, are the migration surface), and any flip is its own decision with a deprecation note for `perKeySettle`. `settleFixed` is not deprecated by this RFC.

## Scope decision: testing-only, no flag — enforced by types, not directories

Decided at round 1 (question raised by Corey); refined at round 2 (BusyGate re-homed). Layers with different reach:

- **intonaco accessors** (`reactiveIdle`, `reactivePendingCount`, `animationsIdle`): general-purpose read-only introspection — plain exports, no flag. They serve reactive observability and are the layer a sibling frontend would build *its* drain from.
- **fresco probes** (`commitIdle`, `surfaceIdle`): production-safe read-only observability (e.g. a devtools "surface settled" indicator) — plain exports.
- **`busy` module** (`BusyGate`, `BusyPredicate`, `withBusy`, `anyBusy` — M5): general-purpose — not test-gated, not homed in `headless/` (round 2).
- **`drainToIdle` + drain settling**: test-support. The **primary protection is the signature**: `InlineScreen[MemorySink]` cannot compile against a `TerminalSink` screen, so a production caller cannot reach the pump-loop idiom by accident — a compile-time-enforced boundary, on-thesis, and stronger than directory convention (Nim has no "test-only module" concept; nothing stops a production binary from importing `fresco/headless/runner` — the type constraint is what actually closes that gap). Module placement in `headless/` is the secondary, convention-level signal. A `-d:` flag would add friction without adding any protection the type doesn't already give.

Sinopia note: sinopia is a *separate frontend* on intonaco — it never sees fresco's `InlineScreen`, so genericizing `drainToIdle` over `Sink` would not serve it; it composes its own drain from the intonaco accessors. (Its RFC does not yet name this need; the accessors' justification is reactive observability first, sinopia speculatively.) Production graceful-teardown (`inline_teardown.nim`) hand-implements a narrower flush today; consolidating it onto a generic drain would be a production-behavior change, out of scope per the upstream request's non-goals — noted as possible future work, deliberately not built speculatively.

## Out of scope (tracked, not silently dropped)

- **Drain settling for the plain Layout overload / `Screen` / `AltScreen`:** these have the same reactive/animation/dirty-region races minus the commit batcher, and "migrate to InlineScreen" is not a real path for genuine `Screen`/`AltScreen` consumers. Out of scope here because the requesting consumer (amoxtli) is InlineScreen-based and no current downstream drives the other harness shapes; tracked as fresco issue #114 rather than dismissed.
- **Supervisor restart-window timing tests:** stay on `settleFixed` (model §6).
- **Production teardown consolidation onto a generic drain:** see §Scope.

## Slices

Every slice's definition of done includes **registering its new test file** in the owning package's `task test` block (`fresco.nimble` / `intonaco.nimble` list files by hand — an unregistered file is a silent false-GREEN).

Stage A — intonaco (independent of fresco slices B3–B4; must land before B5):

1. **A1** `reactiveIdle()` / `reactivePendingCount()` in `scheduler.nim` + **new** black-box test `intonaco/tests/test_scheduler_idle.nim` via `import intonaco/reactive` (idle at rest; false for the whole span of an effect body fired during propagation — `gPropagating` covers it; the walker accepts the bare call, verified). Register in `intonaco.nimble`.
2. **A2** `animationsIdle()` in `animation.nim` + **new** black-box test `intonaco/tests/test_animation_idle.nim` (true at rest, false with a live tween, true after completion). No intonaco animation test exists today; crib the real-clock idiom from *fresco's* `tests/integration/test_animation.nim` but write black-box (that file is whitebox/`include`-based — wrong repo and wrong style to extend). Register in `intonaco.nimble`.

Stage B — fresco:

3. **B3** Consolidate `anyPending` into `render/layout.nim` (exported); rewire `screen.nim` + `inline_screen.nim` to it. Pure refactor, suite stays green (verified feasible: `Region.pending`/`Layout.regions` already exported; both callers already import `render/layout`).
4. **B4** `commitIdle` / `surfaceIdle` probes + `tests/unit/test_surface_probes.nim` (at rest both true; `logSink.append` → immediately `not commitIdle` — flag set synchronously before the `callSoon`, no await needed, verified; `markDirty` → `not surfaceIdle` while `commitIdle`). *No intonaco bump required; independent of A1–B3.*
5. **B5** **Pin bump** (the only slice that needs new intonaco): host-side `milpa fetch --upgrade intonaco` (bare `milpa fetch` keeps the lock; `milpa update` is not yet implemented) to regenerate `milpa.lock`/`nim.cfg`, then `./dev test` in-container. Known risk: the pin is branch-`main`, so this pulls *all* intonaco mainline drift since the last pin — expected under "intonaco leads, fresco conforms"; budget for unrelated breakage here, isolated to this slice.
6. **B5a** chronos fork: `pendingCallbacksCount*()` accessor (ready-callback queue depth, sentinel excluded, current dispatcher) + fork-side test — on a **new branch `feat/pending-callbacks-count` cut from `upstream/master`, never on `feat/contextvars`** (independent upstream-PR units); create/refresh the `fresco-pin` integration branch (merge of both) and move the chronos ref in intonaco's milpa manifest to it, then re-lock fresco. Independent of B5; can run in parallel with A1–B4.
7. **B6** `drainToIdle` core: `DrainSpec`, wait clauses (incl. `dcDispatcher`), `stepsAsync(1)` pump, paint postcondition — **single-read semantics, no deadline, no stability window yet** (both deferred; clean RED-GREEN boundaries). New file `tests/unit/test_drain_to_idle.nim`; **every test call site uses `drainToIdle(...).withTimeout(2.seconds)`** so a pump-loop bug fails fast instead of hanging CI (no per-job timeout is configured; the suite has no `withTimeout` precedent to crib — this mandates the idiom). Tests: idle-at-rest returns on first idle read; a scheduled commit completes and post-drain `surfaceIdle()` holds; drain does not wait on a dirty region (paints it instead); **a pushed key is fully delivered before the drain returns** (the model-§7 acceptance test — asserts app-visible state immediately after a single `drainToIdle`, not final state).
8. **B7** Deadline + `DrainTimeoutError` with `failingClauses` (`newException` + field-assign idiom; `msg` populated). Deadline liveness *and* truth via the armed `sleepAsync(spec.drainTimeout)` timer per §3 — no `Moment.now()` anywhere; the timer future is cancelled on every exit path (`defer`). Tests: stuck `busy` raises naming exactly `{dcBusy}` — and raises via the drain's *own* deadline well before the test-site 2 s `withTimeout` (proves internal liveness against the dormant-dispatcher hang, the stage-3 defect); live perpetual tween raises naming `dcAnimations`; `ignoreAnimations = true` settles despite it *and* a concurrent `dcBusy` timeout's set excludes `dcAnimations`; idle-at-deadline breaks instead of raising (microscopic `drainTimeout` on an idle app succeeds).
9. **B8** Adversarial single-read machine tests (the window/backoff deletion itself is recorded in §3). Tests: a mid-drain clause flap (idle → busy → idle, e.g. a commit re-armed from a drained callback) is still caught — the drain does not return while the re-armed work is in flight; sequential `drainToIdle` calls share no state; an already-idle drain returns promptly without waiting on any timer (fast-path latency regression guard against the deleted window's stall mode).
10. **B9** `busy` module (`BusyGate` with sealed `begin`/`finish`, `withBusy`, converter, label) + end-to-end async-turn test: mock awaited call under `withBusy`, drain resolves exactly at resolution; a raising body does not leak the gate; the converter compiles at a `settleDrain(busy = gate)` call site. New file `tests/unit/test_busy_gate.nim`.
11. **B10** `Settle` union + `runHeadless` drain wiring, happy path: `settleDrain` between events, final pre-capture drain, `settleFixed` path untouched. New file `tests/unit/test_settle_drain.nim`. Tests: representative key sequence with a **per-event intermediate-state assertion** (not final-state-only — final-state tests are masked by the trailing `appFut` wait and would hide model-§7 regressions); `events = @[]` (final drain only). *(Superseded by H1, round-1 stage-4: "settleFixed path untouched" described B10's scope at the time, not a permanent asymmetry — H1 gives `skFixed` the same app-death short-circuit `skDrain` already had, so the two paths now agree on script-truncation recording.)*
12. **B11** Failure surfacing: `appFut` short-circuit + `appError`; `SettleFailure` recording (site union) + event short-circuit on drain timeout; final drain best-effort; `CancelGrace` bound on the post-cancel wait; `settled()`. Tests: a never-settling run still returns a `HeadlessResult` with `settleFailures` naming the clause and `settled() == false`; a mid-script app crash stops injection and sets `appError`.
13. **B12** Resize path + port: `ievResize` under drain (`applySizeNow` dirties *every* region — the biggest dirty-set case; fully synchronous, no delivery chain — drain paints, capture correct; crib `tests/unit/test_headless_resize_inject.nim`); port one representative fixed-settle test to `settleDrain`; both settle paths green.
14. **F1** (follow-up, post-ship defect fix) `cancelGraceExpired` on `HeadlessResult` + shared `teardownAppFut(appFut, timeout)` routine replacing the per-overload `withTimeout` teardown in **both** `runHeadless` overloads (the `withTimeout` correction above). Tests in `tests/unit/test_settle_drain.nim`: a cancellation-surviving app (catches `CancelledError` and re-awaits) under `settleDrain` returns with `cancelGraceExpired == true` and `settled() == false`; the same app under `settleFixed` returns the same way (totality, not a settle-mode split); a well-behaved app that outlives the script and honors cancellation promptly returns with `cancelGraceExpired == false` and stays `settled()`.

## Acceptance

Upstream categories mapped to covering mechanism + owning slice (round 2: the categories were never re-walked against the final design; Category A is exactly where the model-§7 gap bit):

| Upstream category | Covered by | Slice |
|---|---|---|
| A — synchronous turn | `dcDispatcher` delivery clause + `dcReactive` invariant + paint postcondition | B6 |
| B — async turn (`responseDelay`) | `busy` predicate (gate or Future-closure) + delivery clause | B9 |
| C — reactive-propagation / status-bar | `dcCommit` + paint postcondition | B6, B10 |
| D — multi-turn | A/B/C composed per event + per-event intermediate assertions | B10, B12 |

- fresco: all slices' tests green under `./dev test`; existing fixed-sleep tests untouched and green (verified: no existing test names `perKeySettle` or constructs `HeadlessResult`).
- Explicit scenario coverage: zero-event runs, sequential drains, key-delivery-before-return, mid-script app crash, never-settling run, resize-under-drain — slices B6, B8, B10, B11, B12.
- Downstream (amoxtli, after re-pin): its ~4 harness wrappers (fan-in for 222 call sites) swap to `settleDrain`; ~214 s collapses toward compute floor; conservation baseline (1871 per-test records) unchanged; settle-race flakiness class gone. (Verified downstream, not in this repo.)

## Logistics

- Order: A1–A2 → B3–B4 (parallel-safe, no bump needed) → B5 pin bump → B5a chronos accessor + pin bump → B6–B12. (B5a is independent of B5 and may land any time before B6.)
- `DrainTimeoutError` is `object of AsyncTimeoutError` (→ `CatchableError`); both `runHeadless` overloads are already `{.async: (raises: [Exception]).}`, so no raises-composition issue at the harness boundary. A future tightly-annotated direct caller of `drainToIdle` must include it (or `AsyncTimeoutError`) in its raises list.
- fresco tag: cut a tagged release after B12 so amoxtli can move `ref=` from bare SHA to a tag (desired in their `milpa.kdl`).
- amoxtli re-pin: amoxtli pins **both** fresco (by commit) and intonaco (direct SHA edge, in addition to the transitive edge through fresco) — its migration must converge both edges to the same intonaco SHA in its `milpa.kdl` + lock, not just bump fresco. The chronos-fork pin joins the same convergence set (B5a).
