# RFC: A reactive transaction model

**Status**: Stub (flagship direction 2 of 5; follow-on to the consistency model)
**Author**: Corey Leavitt
**Companion to**: `docs/roadmap-compile-time-research.md`, `docs/rfc-consistency-model.md`, `intonaco/docs/rfc-modal-tiers.md` (modal framing — this direction adds the `⊠` transactional-necessity modality slot)

## The gap

Software transactional memory (STM) is mature (Haskell STM, Clojure refs, countless DB engines). **Reactive STM is essentially undone.** No signals/FRP substrate offers user-delimited atomic regions over reactive state with abort/commit/retry semantics and isolation guarantees. Reactive systems give you *implicit* per-propagation batching; none gives you *explicit, composable, scoped* transactions. Bringing a transaction discipline to a reactive substrate is a contribution on the gap alone, and intonaco has a uniquely strong starting point.

## The foothold (corrected after the consistency-model review)

intonaco's **speculative scopes** give us the **revert plumbing** — `committed` flag, LIFO revert stack, commit-promotes-to-parent — which is real and reusable. But the first estimate ("~70% of a transaction model") was wrong: speculative scopes implement **read-uncommitted only** (writes mutate the signal and `notify` observers immediately; reads inside the block see the new state). The actual research depth of a transaction model — isolation for push-based observers — is exactly what speculative scopes do *not* provide. So the honest figure is ~30%: we get abort/commit/revert machinery, none of the isolation. What's still missing:

- explicit `commit` / `abort` / `retry` semantics (today revert is failure-driven, not user-controlled)
- **isolation levels** — buffering notifications until commit so observers don't see uncommitted writes (the hard part; speculative explicitly does the opposite)
- composition (nested transactions; what does commit of an inner mean?)
- compile-time validity of nesting and of what operations are legal inside a transaction

(Note for implementers: a comment in `intonaco`'s `speculative.nim` calls nesting "MVCC" — that contradicts the optimistic-revert semantics and `[[reference_speculative]]`; it should be corrected before it misleads this design.)

## The depth

Two genuinely research-grade questions:

1. **Isolation under reactive propagation.** A transaction mutates signals; those signals have observers. When does an observer see the transaction's writes — at each write (read-uncommitted), at commit (read-committed), or never-until-commit-with-a-consistent-snapshot (serializable)? Reactive observers complicate every classical isolation level because observation is *push-based*, not pull-based. Defining and statically enforcing isolation levels for push-based observation is open.

2. **Compositional commit semantics.** Nested reactive transactions, and transactions whose bodies *re-run* (a transaction inside a derivation). What does committing an inner transaction mean when the outer may abort? What does re-execution mean for a transaction's effects? This couples tightly to direction 3 (substructural under re-execution) and direction 1 (the consistency model defines re-execution count).

## Nim leverage

- **Concepts** for transaction-legal operations (a `Transactional` effect-shape the body must satisfy).
- **Typed macros** for compile-time nesting validity and static commit-point detection.
- **ORC/ARC deterministic destruction** for abort cleanup — scope exit triggers revert deterministically.
- **chronos `contextVar`** to carry the active transaction across `await` (the same CLS mechanism speculative scopes already use).

## Surface (sketch)

```nim
transaction:
  account.balance := account.balance() - amount
  recipient.balance := recipient.balance() + amount
  if account.balance() < 0:
    abort        # both writes revert; observers never saw an inconsistent pair
  # implicit commit at scope exit; observers fire once, atomically
```

## Relationship to other directions

- **Consistency model (1)** is the prerequisite: transactions are the *explicit scoped strengthening* of the implicit per-propagation atomicity that the consistency model defines. This RFC builds directly on it.
- **Substructural (3)**: a transaction boundary is a natural consumption boundary for scope-bounded linearity.

## Research artifact

Paper on transactional semantics for push-based reactive substrates — isolation levels for observer-driven reads, and compositional commit under re-execution. Novelty is the push-based-observation interaction, not transactions per se.

## Estimated effort

4 months. ~1000 LoC, much of it generalizing the existing speculative-scope machinery rather than greenfield.

## To be expanded

Full RFC after the consistency model locks (this direction's semantics are defined in terms of it).
