# RFC: Type-level temporal invariants for reactive signals

**Status**: Stub
**Author**: Corey Leavitt
**Companion to**: `docs/roadmap-compile-time-research.md` (direction 4 of 6), `docs/rfc-information-flow.md` (prerequisite)

## Premise

Signals carry temporal invariants at the type level. Compile-time verification that every write preserves the invariant.

Goes beyond Rust's type-level constants (static values) to *dynamic-value invariants* tracked through the reactive graph: a signal's current value can change, but the invariant on its value-over-time must hold.

## Surface (sketch)

```nim
let counter: Signal[Monotonic[int]] = signal(0)
counter.set(counter() + 1)   # OK
counter.set(counter() - 1)   # compile error: violates Monotonic

let progress: Signal[Bounded[float, 0.0..1.0]] = signal(0.0)
progress.set(0.5)            # OK
progress.set(1.5)            # compile error: out of bounds

let cache: Signal[EventuallyConsistent[Pair[Key, Value]]] = ...
# verified at compile time: writes to A and B within K events maintain consistency
```

## Engineering primitives that fall out

- `Monotonic[T]`, `Bounded[T, range]`, `EventuallyConsistent[...]`, `StableWithin[Duration]` invariant types
- Compile-time write-validity checking
- Provably-monotonic counters
- Provably-clamped progress indicators
- Provably-bounded rate limiters
- Static stability proofs for UI (no flicker invariant)
- Static cycle detection as a side product

## Research contribution

TLA+-style temporal logic adapted to compile-time-checked reactive signals. Prior work runtime-verifies temporal properties (TLA+ trace checking, runtime assertion frameworks). Doing it at compile time over the type system is novel.

## Estimated effort

4 months. ~1200 LoC.

## Prerequisites

Information-flow (1) for the type-level extension machinery.

## To be expanded

Full RFC after information-flow Phase 3.
