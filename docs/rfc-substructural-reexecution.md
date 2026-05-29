# RFC: Substructural types under reactive re-execution

**Status**: Stub (flagship direction 3 of 5)
**Author**: Corey Leavitt
**Companion to**: `docs/roadmap-compile-time-research.md`

## The gap

Substructural typing — linear (use exactly once), affine (use at most once), bounded (use at most N times) — is well-developed in the broader language-theory world (linear logic, Linear Haskell, Rust's ownership, session types). It is **entirely absent from reactive substrates**. No signals/FRP library tracks resource cardinality through the reactive graph. Bringing substructural caps to a reactive substrate is a legitimate contribution on the gap alone: one-time deploy tokens, transactional resource handles, single-shot speculative scopes, rate-limited API budgets — all statically verified rather than runtime-asserted.

## The depth — the part that is genuinely novel

Classical substructural type systems assume **single execution**. Reactive substrates violate that assumption at their core: **a derivation body re-runs every time a dependency changes.** A `createComputed` whose body consumes a linear resource consumes it once *per execution* but arbitrarily many times over the signal's lifetime.

So the research question is not "can we have linear caps" (yes, trivially, on the gap). It is:

> **What does linearity mean under multi-shot reactive re-execution, and how is it statically enforced?**

Candidate semantics, none obviously correct, all needing formalization:

- **Per-execution linearity** — the cap is linear *within* one derivation run; re-execution re-grants it. (Closest to classical; weakest guarantee.)
- **Per-lifetime linearity** — the cap is consumed once across the signal's entire life; re-execution must *not* re-consume. (Strongest; requires the substrate to remember consumption across runs.)
- **Scope-bounded linearity** — consumption is linear within a supervision scope; the scope's lifetime, not the derivation's, is the accounting boundary.

The honest risk, flagged at lock time: **re-execution may dissolve linearity rather than refine it.** If the only coherent semantics is per-execution, the "novel" theorem collapses to classical linearity applied per-run, and the contribution reverts to the gap-level port. That is an acceptable floor — the direction survives either way — but the headline depends on per-lifetime or scope-bounded linearity admitting a sound, decidable static discipline.

## Nim leverage

- **Concepts** for cap shape and cardinality constraints (`Grants*`-style structural typing already in intonaco).
- **Typed macros** to track consumption sites across the C-shape walker — the same walk that produces dependency edges produces consumption multisets.
- **ORC/ARC deterministic destruction** as a natural enforcement hook: a linear cap's destructor firing is the consumption witness.
- **`static[T]`** for `Bounded[N]` with compile-time N; runtime-N is a stretch goal needing a hybrid check.

## Surface (sketch, semantics TBD by the depth question)

```nim
cap DeployToken, cardinality = Linear
cap ConnectionHandle, cardinality = Affine
cap RateLimitedCall, cardinality = Bounded[100]

proc deploy(t: DeployToken) {.needs: DeployToken.} =
  consume t   # static consumption witness

# Open question the RFC must answer:
let url = createComputed:
  deploy(token)        # body re-runs on dependency change.
  # per-execution:  legal every run
  # per-lifetime:   compile error — re-execution would re-consume a linear cap
```

## Relationship to other directions

- **Consistency model (1)** and **transactions (2)**: a transaction's commit/abort is a natural consumption boundary; scope-bounded linearity may be definable in terms of transaction scopes.
- **Shared walker platform**: consumption multiset is the same C-shape walker, projected.

## Research artifact

Paper on substructural typing under reactive re-execution semantics. The novelty claim is the re-execution interaction, not linearity itself. If the depth pans out, this is a genuine contribution to substructural type theory (a setting classical systems don't model); if it doesn't, it's a solid substrate-gap port documented honestly.

## Estimated effort

3 months. ~800 LoC + macro work + the semantics decision up front.

## To be expanded

Full RFC after the consistency model lands and the re-execution semantics question is pressure-tested.
