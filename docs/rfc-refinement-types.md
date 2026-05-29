# RFC: Refinement types for reactive signals

**Status**: Stub (flagship direction 4 of 5)
**Author**: Corey Leavitt
**Companion to**: `docs/roadmap-compile-time-research.md`, `intonaco/docs/rfc-modal-tiers.md` (modal framing — this direction adds the `□{v | P(v)}` refined-necessity modality slot)

## The gap

Refinement types — types carrying a predicate the value must satisfy (`{v: int | v >= 0}`) — are well-studied (Liquid Haskell, F\*, Liquid types). They are **absent from reactive substrates over mutable values**. A signal's value changes over its lifetime; no reactive library statically guarantees that *every* write preserves a value-domain invariant. Today this is runtime assertion or convention. Bringing refinement types to reactive signals is a contribution on the gap alone.

This direction is the honest core of what the old "temporal invariants" stub conflated. The grab-bag split three ways:

- `EventuallyConsistent` → belongs to the **consistency model** (direction 1), not here.
- `StableWithin[ms]` → a timing property, overlaps scheduler/animation concerns and the bracketed timing-channel anti-case. **Dropped.**
- `Monotonic`, `Bounded` → value-domain invariants. **The honest core, kept here.**

"Temporal" was a misnomer; these are refinement types, not temporal logic.

## The depth — the part that is genuinely novel

Classical refinement-type settings reason about comparatively static bindings. Reactive signals are **mutable values written an unbounded number of times over their lifetime**, and the invariant must hold across *all* writes — including writes inside derivations that re-run.

> **The contribution: refinement types where the predicate is an invariant over an unbounded write sequence, with every write site discovered and discharged at compile time via the reactive graph.**

- `Bounded[T, lo..hi]` — a refinement (`{v | lo <= v <= hi}`); every `set` must provably land in range.
- `Monotonic[T]` — a *relation between successive values* (`{v' | v' >= v}`), which is richer than a unary refinement and is where the reactive setting earns its novelty: the macro must prove the relation holds between the prior signal value and every write.

The static engine finds every write site through the C-shape explicit-deps walker and discharges the predicate (constant writes: trivially; computed writes: via the body's available facts). Where the predicate can't be discharged statically, three-tier diagnosis (compile error → static-assert with hint → runtime guard) mirrors the consistency model's diagnostic discipline.

## Nim leverage

- **`static[T]`** for compile-time bounds (`Bounded[float, 0.0..1.0]`).
- **Typed macros** to enumerate write sites from the C-shape walker and emit per-site discharge obligations.
- **`distinct T`** + `borrow` for the refined signal type without runtime overhead.
- **Concepts** for the relation kind (unary refinement vs successive-value relation).
- Possible **term-rewriting macros** to fold provable-in-range writes to unchecked sets.

## Surface (sketch)

```nim
let progress = signal[Bounded[float, 0.0..1.0]](0.0)
progress.set(0.5)     # OK — provably in range
progress.set(1.5)     # compile error — 1.5 ∉ 0.0..1.0

let counter = signal[Monotonic[int]](0)
counter.set(counter() + 1)   # OK — successive-value relation holds
counter.set(counter() - 1)   # compile error — violates Monotonic
```

## Relationship to other directions

- **Consistency model (1)**: shares the three-tier diagnostic machinery and the write-site enumeration from the shared walker. `EventuallyConsistent` lives there, not here.
- **Substructural (3)**: a refinement and a cardinality are orthogonal projections of the same walk; both compose on one signal.

## Research artifact

Paper on refinement types over reactive mutable values. Novelty: the invariant-over-unbounded-write-sequence setting, and the successive-value relational refinements (Monotonic-style) that unary refinement systems don't model.

## Estimated effort

4 months. ~1200 LoC + macro work + tests.

## To be expanded

Full RFC after the consistency model lands (shares the write-site walker and diagnostic tiers).
