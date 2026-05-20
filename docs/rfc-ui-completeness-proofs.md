# RFC: Static UI completeness proofs

**Status**: Stub
**Author**: Corey Leavitt
**Companion to**: `docs/roadmap-compile-time-research.md` (direction 5 of 6), `docs/rfc-effect-classification.md` (prerequisite). Bridges `intonaco` (verification) and `fresco` (rendering).

## Premise

Given the reactive graph and the typed state model, prove at compile time:

- **Exhaustiveness**: for every state variant, some binding renders it
- **Reachability**: every binding is reachable from some user input or external event
- **Liveness**: bindings whose preconditions hold will eventually render
- **Determinism**: same input sequence produces same render output (given the journal)

Like exhaustiveness checking for `case` statements, generalized to the reactive UI graph.

## Surface (sketch)

```nim
type AppState = enum
  asLoading, asReady, asError

let state: Signal[AppState] = signal(asLoading)

bindRow region, 0:
  case state()
  of asLoading: "..."
  of asReady: "Welcome!"
  # compile error: no binding for asError variant
```

The macro analysis walks the reactive graph, checks that every variant of state-discriminator types has a corresponding binding output. Subset of standard exhaustiveness checking, generalized to the reactive substrate.

## Engineering primitives that fall out

- Compile error when a state variant has no binding
- Compile error when a binding is dead (no reachable input causes it to fire)
- Compile-time liveness proofs for critical UI paths
- Journal-based determinism verification (given a journal, the projected render output is deterministic)

## Research contribution

Practical UI completeness checking at the language level, with the reactive substrate providing the necessary structural information. Connects to academic FRP frameworks (Concur, others) that proved similar properties but never shipped as usable libraries.

## Estimated effort

5 months. ~1500 LoC. Bridges intonaco + fresco; substantial coordination across the package boundary.

## Prerequisites

Effect classification (2). Benefits from temporal invariants (4) for liveness proofs.

## To be expanded

Full RFC after effect classification Phase 3.
