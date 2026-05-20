# RFC: Linear / affine capability tokens

**Status**: Stub
**Author**: Corey Leavitt
**Companion to**: `docs/roadmap-compile-time-research.md` (direction 3 of 6), `docs/rfc-effect-classification.md` (prerequisite)

## Premise

The cap concept system today is Boolean — you have the cap or you don't. Lift to **substructural** typing where caps carry cardinality:

- **Linear**: must be consumed exactly once
- **Affine**: may be consumed at most once
- **Bounded[N]**: may be consumed up to N times

Borrows from Rust's affine types and from linear logic. Compile-time tracking of cap-token consumption.

## Surface (sketch)

```nim
cap DeployToken, cardinality = Linear
cap ConnectionHandle, cardinality = Affine
cap RateLimitedAPICall, cardinality = Bounded[100]

proc deploy(t: DeployToken) {.needs: DeployToken.} =
  # statically tracked: this consumes t. compile error if t is used elsewhere.
  ...

# In wiring:
let sup = supervisor:
  provides(DeployToken)  # one token granted

deploy(...)  # OK, consumes the token
deploy(...)  # compile error: DeployToken already consumed
```

## Engineering primitives that fall out

- `cap T, cardinality = ...` cardinality-annotated cap declarations
- Compile-time consumption tracking
- One-time deploy tokens
- Transactional resource handles
- Single-shot speculative scopes
- Rate-limited API budgets

## Research contribution

Substructural capability typing in a reactive substrate. Connection to Rust's ownership; novelty in dynamic-cardinality (Bounded[N] with runtime N) and in the interaction with reactive observer dispatch.

## Estimated effort

3 months. ~800 LoC.

## Prerequisites

Effect classification (provides the consumption-as-effect machinery).

## To be expanded

Full RFC after effect classification Phase 2.
