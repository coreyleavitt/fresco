# RFC: Reactive ABI stability checking

**Status**: Stub (latest in the research roadmap; depends on all five other directions)
**Author**: Corey Leavitt
**Companion to**: `docs/roadmap-compile-time-research.md` (direction 6 of 6).

## Premise

A program or library declares a *reactive surface* — its set of public signals, their types, the bindings/effects users can attach. ABI compatibility is statically verifiable: V2 of a library is backward-compatible with V1 if every V1 consumer's bindings still type-check against V2's surface.

Like semver but actually verified rather than human-declared.

## Surface (sketch)

```nim
reactiveAbi v1:
  signal counter: Signal[Monotonic[int]]
  signal username: Signal[Trusted[string]]
  effect onCounterChange(c: int) {.needs: ObserverCap.}

# In v2 of the library:
reactiveAbi v2 extends v1:
  signal counter: Signal[Monotonic[int]]              # unchanged
  signal username: Signal[Trusted[string]]             # unchanged
  signal email: Signal[Trusted[string]]                # NEW — backward compatible
  effect onCounterChange(c: int) {.needs: ObserverCap.}  # unchanged

# This compiles: extensions to the surface are backward-compatible
# additions don't break v1 consumers.

# In v3:
reactiveAbi v3 extends v2:
  signal counter: Signal[Monotonic[int64]]   # type widened
  # compile error: existing v1/v2 consumers may rely on Signal[Monotonic[int]]
  # which is not a supertype of Signal[Monotonic[int64]]
```

## Engineering primitives that fall out

- `reactiveAbi:` macro declaring a public reactive surface
- Compile-time backward-compatibility checking
- Plugin system support (plugins declare what they touch; host verifies)
- Multi-process versioning (IPC contracts between processes are reactive surfaces)
- Documentation generation from reactive surfaces

## Research contribution

Reactive-graph ABI stability. Most ABI work targets function signatures; reactive ABI is novel because the unit of stability is a reactive-graph node and its observers/transformations.

Synthesizes the other five research directions:
- Information flow labels are part of a signal's ABI type
- Effect/intent classifications are part of an effect's ABI
- Linear cap cardinalities are part of a cap's ABI
- Temporal invariants are part of a signal's ABI
- UI completeness obligations are part of a binding's ABI

## Estimated effort

4 months. ~1000 LoC + tooling for compatibility checking + tests. Less new substrate, more synthesis across the existing substrate.

## Prerequisites

Ideally all five other directions. A partial implementation can ship earlier with future-extension hooks for axes not yet built.

## To be expanded

Full RFC after at least three of (1)-(5) are well-defined.
