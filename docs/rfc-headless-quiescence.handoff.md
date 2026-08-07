# rfc-headless-quiescence — handoff

- **Stage:** 3 tdd COMPLETE (all 13 slices landed; final suite 823 OK / 0 FAIL)   •   next: stage 4 code review
- **Resume:** `/code-review docs/rfc-headless-quiescence.md scope — headless quiescence: src/fresco/headless/runner.nim, src/fresco/busy.nim, render/layout.nim anyPending, inline_screen.nim probes, intonaco accessors, chronos fork pendingCallbacksCount`
- **Post-review follow-ups (recorded, not yet done):** fresco tag after review ships; upstream chronos ISSUE documenting the dormant-stepsAsync select() gotcha (see RFC §Design 3); amoxtli converges fresco+intonaco+chronos pins (out of scope here).

## Pre-review follow-ups (Corey-approved 2026-08-07, before stage 4)
- [ ] F1 CancelGrace expiry surfacing: grace elapsing with appFut still pending is currently invisible (`settled(r)` reads true while a live app future is abandoned). Add `cancelGraceExpired`-class field to HeadlessResult, fold into `settled()`; RFC edit + TDD test. (Routine teardown-cancel stays invisible by design — chronos Cancelled ≠ Failed, so appError doesn't capture it; verify.)
- [ ] F2 BusyPredicate compile-time contract spike: intonaco already ships `{.forbids: [ReactiveRead, ReactiveWrite].}` machinery, refuting round-2's "no mechanical enforcement possible". Probe closure effect inference; adopt the forbidding proc type if it holds, else record the proof-of-impossibility in the RFC (no-invariant-dismissal).
- [ ] F3 upstream chronos issue (dormant-stepsAsync select() gotcha): draft for Corey's approval before filing — outward-facing.

## Open forks (awaiting Corey)
- (none — B7 liveness fork RESOLVED 2026-08-06: Corey approved the full redesign. Deadline-timer machine for B7; B8's stability window + backoff DELETED from the RFC machine. RFC §Design 3 rewritten accordingly; see Key decisions below.)

## Delivery-gap resolution (round-2 critical → decided)

`pushKey` → app continuation crosses ≥4 chained `callSoon` hops during which every drain clause is vacuously idle; no fixed stability window is sound (hop count is app-topology-dependent). **Decided: `pendingCallbacksCount*()` in our chronos fork → `dcDispatcher` clause** (exact witness: every hop IS a ready callback; timers excluded naturally; accounting clean at the check site since the drain's next pump isn't yet scheduled). Upstream due diligence recorded in the RFC: never proposed/rejected upstream; introspection is an accepted upstream category (stepsAsync/idleAsync "for deterministic tests"; PR #85 metrics merged 2020, later culled — pitch the accessor in the debugutils family, not metrics; chronosFutureTracking + pendingFuturesCount is CURRENT upstream API); fork already load-bearing for contextVar so no new permanent commitment; and `-d:chronosFutureTracking`+`pendingFuturesCount` is a validated-on-paper no-fork fallback (delicate accounting: destructor lag + pump self-noise — needs a spike if ever swapped in), so we can never be fork-locked on this feature.

## Slices (13 — see RFC §Slices)
- [x] A1 intonaco: reactiveIdle/reactivePendingCount + NEW tests/test_scheduler_idle.nim (register in intonaco.nimble) — intonaco `a9188fa`, 132 OK
- [x] A2 intonaco: animationsIdle + NEW tests/test_animation_idle.nim — intonaco `b54aa96`, 136 OK
- [x] B3 fresco: consolidate anyPending into render/layout.nim — fresco `e1b20c8`; 74/80 test files pass; 6 PRE-EXISTING failures (5× contextVar undeclared-identifier via pinned intonaco, 1× proptest not mounted in ./dev) confirmed present at clean HEAD by stash-bisection. Baseline regression root-caused + fixed: `012601e` (dev script now mounts local milpa dev-deps → proptest) + `c261ed0` (5 substrate-floor tests migrated to `include intonaco/reactive_internal`; chronos fork's export-marker gating fix on floating `feat/contextvars` ref had removed the leniency they relied on). Baseline now 784 OK / 0 FAIL.
- [x] B4 fresco: commitIdle/surfaceIdle probes + tests/unit/test_surface_probes.nim — fresco `79c299e`, 787 OK
- [x] B5 fresco: intonaco pin bump `1b085b2d`→`b54aa96c` (intonaco main pushed to origin first — milpa fetches GitHub, not local) + reachability probe test — fresco `1b81231`, 788 OK. NB fresco gitignores milpa.lock by design.
- [x] B5a chronos fork: pendingCallbacksCount on `feat/pending-callbacks-count` (chronos `3fc1b04`, off upstream/master, feat/contextvars untouched) + 3 fork tests in testsoon.nim (orc+refc green); `fresco-pin` integration merge `b4262db`; intonaco manifest ref→fresco-pin (`be74d60`); fresco re-locked, probe OK, 788 OK. SIDE-FINDING fixed: intonaco tests/test_collection.nim migrated to substrate-floor include (intonaco `e9d576d`, 136 OK restored; duplication audit clean — only deliberate negative tests remain).
- [x] B6 drainToIdle core — fresco `049fdc4`, 792 OK; dcDispatcher empirically validated (disabling it fails the key-delivery test); BusyPredicate temporarily homed in runner.nim pending B9
- [x] B7 deadline + DrainTimeoutError via armed sleepAsync(drainTimeout) timer (liveness + deadline truth, no Moment.now()) — fresco `77488a1`, 797 OK; dormant-dispatcher regression test included
- [x] B8 adversarial single-read tests — fresco `503dfac`, 800 OK; machine held under all scenarios, no defect
- [x] B9 busy module src/fresco/busy.nim (sealed begin/finish, converter, label; BusyPredicate re-homed) — fresco `6260fad`, 808 OK
- [x] B10 Settle union + drain-mode runHeadless wiring (fixed path unchanged/default; unconditional final drain) — fresco `e26d4e3`, 813 OK; per-event intermediate assertion non-vacuity proven
- [x] B11 failure surfacing (SettleFailure sfEvent/sfFinalDrain, appError, settled(), CancelGrace; short-circuit-on-timeout per RFC) — fresco `988d04a`, 820 OK
- [x] B12 resize-under-drain composition tests + drain-mode port of the representative resize test + §Acceptance A–D table closed — fresco `238b0a7`, 823 OK. No production change needed (B10's skDrain loop already applied ievResize via setSize); non-vacuity proven by reverting the resize arm (3 tests fail, rest unaffected). Acceptance: A→test_drain_to_idle (B6), B→test_busy_gate (B9), C→dcCommit+paint tests, D→per-event intermediate assertion + new resize-while-busy composition test.

## Key decisions (stage 3, applied)
- **stepsAsync dormant-dispatcher liveness hole (B7 blocker → redesign, Corey-approved 2026-08-06):** `stepsAsync` continuations ride the tick queue, which neither bounds `select()`'s timeout nor drains before it — a pump on a dormant dispatcher hangs forever (standalone chronos repro). Fix: arm `sleepAsync(spec.drainTimeout)` once at drain entry as BOTH liveness bound and deadline truth (raise iff timer finished ∧ clause set non-empty; no `Moment.now()`); keep stepsAsync(1) as the event-driven pump. NOT a chronos fork patch (upstream semantic defensible; keeps fork minimal — file an upstream ISSUE documenting the gotcha instead).
- **Stability window + backoff deleted (same approval):** backoff's premise (busy waits spin) is false — dormant waits sleep in select() at 0 CPU, and backoff could never engage from dormancy (needs 10 completed pumps). The window would stall every already-idle drain until the deadline under the event-driven pump, and its insurance role is obsolete — dcDispatcher makes a single idle read sound. B8 re-scoped to adversarial tests of the single-read machine.

## Key decisions (round 2, applied)
- **Vocabulary converged:** *Idle = probes, Drain* = mechanism (DrainClause dc*, DrainTimeoutError, DrainSpec), Settle* = harness policy, `settled(r)` = result predicate. No Quiescence* types (kept in prose only); Error suffix per house convention.
- **DrainSpec** unifies drainToIdle params with Settle.skDrain payload — one declaration, drift impossible (same argument that killed the flat enum in round 1, one level down).
- **State machine fixes:** clause-set evaluated ONCE per iteration (raise reuses the same set — no divergence; ignored clauses never appear); deadline checked only before re-pumping, idle-at-deadline breaks (empty-set raise unrepresentable); newException+field idiom (object-construction raise doesn't compile for non-ref exceptions; zero in-repo precedent); backoff-tail cost note (~1 ms × window post-backoff, not "~4 polls").
- **BusyGate:** moved to src/fresco/busy.nim (general-purpose, not MemorySink-gated — headless homing sent false test-only signal); begin/finish module-private (LogSink capability precedent; underflow unrepresentable); converter BusyGate→BusyPredicate (Subscribable precedent); label for consumer-side multi-gate diagnostics. Grounding: amoxtli's real predicate is a bare closure over Future refs (isReplBusy), NOT a gate; 222 call sites funnel through ~4 wrappers — wrappers are the migration surface.
- **SettleFailure:** eventIndex=-1 sentinel → discriminated union {site: sfEvent(eventIndex)/sfFinalDrain} (the exact invalid-state shape §5 rejects).
- **Wall-clock formula fixed:** post-cancel `await appFut` was unbounded (race-no-cancel memory) → drain mode bounds it with CancelGrace=100ms; fixed path untouched.
- **BusyPredicate contract relabeled** honest footgun (context-free reads: plain fields/Future.finished; no mechanical enforcement possible for wrong-context reactive reads) per no-invariant-dismissal.
- **Cancellation contract stated:** CancelledError propagates without painting; withBusy finally still runs; concurrent drains safe-by-construction note.
- **Slice fixes:** B6/B8 boundary un-blurred (B6 single-read, B8 window+backoff); A2's "existing test_animation.nim" claim corrected (doesn't exist in intonaco; fresco's is whitebox); every slice names its test file + nimble registration in definition-of-done; withTimeout(2s) mandated on all B6+ drain test sites (no CI job timeout configured).
- **Acceptance:** upstream Categories A–D now mapped to clause+slice in a table (the missing cross-check that would have caught the delivery gap earlier).

## Key decisions (round 1, still standing)
- Layout dirtiness NOT a wait clause → paint postcondition. Settle discriminated union. Primitive-raises/harness-reports failure semantics. reactiveIdle = invariant assertion (propagation provably synchronous incl. gDeferred). Scope: testing-only, NO flag, InlineScreen[MemorySink] as compile-time protection; intonaco accessors + probes general-purpose. settleFixed stays default until amoxtli migration. Screen/AltScreen deferral → fresco#114. animationsIdle polarity. stepsAsync(1) pump ≈ 2 polls.
- Corrections vs amoxtli upstream request: gDeferred synchronous; commit flags module-private → probes; animationsPending→animationsIdle; (round 2 adds) "app-level predicate is exact" disproven by delivery gap.

## Review ledger
| round | lens | critical/high applied |
|-------|------|----------------------|
| 1 | depth | dirty-layout wait clause (critical→paint postcondition); timeout semantics split; stability-window honesty; busy contract; runAfterPropagation-spawn example |
| 1 | breadth | task-system blindness; app-death masking; Layout-overload hole (→#114); spinner escape; two-pin logistics |
| 1 | design | Settle union; BusyGate/withBusy; structured timeout; polarity rename; anyPending consolidation; MemorySink-as-protection |
| 1 | feasibility | milpa fetch --upgrade; slice resequencing; slice 6/7 raise boundary; final-drain contract (critical); stepsAsync(1) |
| 2 | breadth | **input-delivery gap (CRITICAL → open fork)**; category A–D acceptance table; cancellation contract; BusyGate label; concurrent-drain note |
| 2 | depth | deadline-before-idle-read ordering (high); unbounded post-cancel tail (high→CancelGrace); empty .msg; currentlyFailing contract; busy-contract honesty; backoff cost |
| 2 | design | begin/finish sealed (high); BusyGate re-homed to busy.nim (high); DrainSpec unification (high); SettleFailure union; Drain* vocabulary; settled(); converter |
| 2 | feasibility | **raise-by-object-construction won't compile (CRITICAL → newException idiom)**; B6/B8 boundary contradiction (high); A2 phantom test file (high); withTimeout mandate; nimble registration; Moment.now() first-use |
| 2 | verified-clean | commit batcher fully sync; paint can't re-arm commit; stepsAsync/AsyncTimeoutError exist at pinned chronos 9066085; walker accepts bare reactiveIdle() in effect bodies; re-export chain surfaces accessors; HeadlessResult additions source-compatible; enum prefixes conform |
