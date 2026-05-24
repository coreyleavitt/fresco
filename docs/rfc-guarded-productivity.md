# RFC: Guarded productivity for reactive derivations

**Status**: Stub (flagship direction 5 of 5)
**Author**: Corey Leavitt
**Companion to**: `docs/roadmap-compile-time-research.md`, `docs/rfc-consistency-model.md`

## The gap

Guarded recursion, coinduction, and productivity checking are well-developed in type theory (guarded type theory, sized types, Agda/Coq productivity checkers, Nakano's modal μ). They are **absent from reactive substrates.** No signals/FRP library statically distinguishes a reactive structure that *legitimately* loops forever while making progress (an animation clock, a polling stream, a self-referential layout) from one that diverges (an unproductive feedback loop that recomputes without progress). Bringing productivity checking to reactive derivations is a contribution on the gap alone.

This is distinct from cycle detection. The consistency model (direction 1) requires the reactive graph be acyclic and *errors on cycles*. But not every cycle is a bug — some reactive structures are intentionally cyclic and coinductively productive. Guarded productivity is what lets the substrate **admit the good cycles and reject the bad ones**, instead of banning all cycles. (This direction sources its cycle/SCC machinery and re-execution-count definition from the **shared `tracked:` walker platform** and direction 1's definitions. Guardedness is decided pre-scheduling as a graph-topology property, which is what keeps the two directions non-circular — see the consistency RFC's stratification note.)

## The depth

Two layers:

1. **Termination of the acyclic / well-founded case** — largely the cycle-detection work (Tarjan SCC). This is engineering, not the research contribution; it's the floor.

2. **Productivity of the coinductive case** — the genuine contribution. A self-referential derivation is **productive** iff every cycle through it passes through a *guard* (a delay / next-step operator) that ensures each turn of the loop produces an observable output before depending on its own future value. Statically proving guardedness for reactive derivations — that a feedback loop advances rather than spins — is open in this setting.

> **The claim:** the `tracked:` graph plus a delay/guard marker is enough to decide, at compile time, whether a cyclic reactive structure is productive — turning "no cycles allowed" into "exactly the productive cycles allowed."

## Nim leverage

- **Typed macros** to detect cycles in the `tracked:` graph and check each cycle for an intervening guard.
- **A guard combinator** (a `next`/`delay`-style primitive marking a one-tick deferral) the productivity checker keys on — implementable over the existing animation-frame clock.
- **Concepts** to type guarded vs unguarded self-reference.
- **`std/macrocache`** to memoize the per-SCC productivity verdict.

## Surface (sketch)

```nim
# Productive: the clock advances through a guard each frame.
let clock = createComputed:
  next(clock) + 1        # `next` is the guard — depends on PRIOR self, advances

# Unproductive: depends on its own CURRENT value with no guard.
let bad = createComputed:
  bad() + 1              # compile error: unguarded self-reference, diverges
```

## Relationship to other directions

- **Consistency model (1)**: provides the cycle/SCC machinery and defines re-execution; this direction extends "cycles are errors" to "unproductive cycles are errors." Tight coupling — could be read as the coinductive complement of the consistency model, but it's a flagship in its own right because guardedness is a substantial type-theoretic contribution, not a corollary.
- **Substructural (3)** and **refinement (4)**: a productive cycle still must respect cardinality and refinement invariants on each turn.

## Research artifact

Paper on guarded productivity for reactive derivations — adapting guarded recursion / coinductive productivity to a signals substrate, decided from the static dependency graph. Novelty: the substrate setting and the compile-time decision from `tracked:`, not guarded recursion itself.

## Estimated effort

4 months. ~1000 LoC + macro work + the guard primitive + the productivity decision procedure + tests.

## To be expanded

Full RFC after the consistency model lands (shares the SCC machinery and the re-execution definition).
