# RFC: Effect / intent classification — three-axis static verification

**Status**: Stub (to be expanded post information-flow RFC)
**Author**: Corey Leavitt
**Companion to**: `docs/roadmap-compile-time-research.md` (direction 2 of 6), `docs/rfc-information-flow.md` (prerequisite)

## Premise

intonaco's cap concept system tracks *authority* (what code is allowed to do). Add two orthogonal axes:

- **Effects**: what code *actually does* — pure / signal-read / signal-write / async-suspend / IO / blocking. Inferred by macro analysis of the proc body.
- **Intent**: what code is *trying to accomplish* — render / decide / fetch / mutate / audit / supervise. User-declared via pragma, machine-checked for consistency with inferred effects.

Compile-time verification ensures declared intent matches inferred effects (a `render` intent doesn't mutate; a `pure` intent doesn't suspend; an `audit` intent has the right cap; etc.).

This is Koka-style effect inference adapted to reactive systems. Prior effect systems assume sequential code; reactive systems have *temporal* effects (signal writes propagate to observers eventually). The contribution is the temporal extension.

## Surface (sketch)

```nim
proc renderStatus(sup: auto) {.effect: render, needs: TruecolorCap.} =
  # macro inferred: signal-read effects only. matches declared 'render' intent.
  let s = currentStatus()
  emitPill(s)

proc updateCount(delta: int) {.effect: mutate.} =
  # macro inferred: signal-write effects. matches declared 'mutate' intent.
  count := count() + delta

proc analyzeData() {.effect: pure.} =
  # macro inferred: pure (no signal writes, no IO, no async).
  # compile error if any non-pure operation appears.
  ...
```

## Engineering primitives that fall out

- `{.effect: <intent>.}` pragma
- Compile-time intent/effect mismatch errors
- Pure-function memoization (when effect is `pure`, results can be memoized safely)
- Specialized notification dispatch for pure computations
- Effect deduplication across observers
- Static "is this pure?" introspection helper for tooling

## Research contribution

Koka adapted to reactive. Paper claim: temporal effect propagation is the novel axis; effects in reactive systems must account for downstream observer firing as part of the effect set, not just the immediate code.

## Estimated effort

4 months. ~1500 LoC.

## Prerequisites

Information-flow RFC (Phase 1-2) — provides the type-level extension machinery.

## To be expanded

This stub will become a full RFC once information-flow Phase 3 is well-defined.
