# Roadmap: compile-time-first research substrate

**Status**: Active roadmap
**Author**: Corey Leavitt
**Companion to**: `docs/rfc-intonaco-fresco-split.md` (the identity & structural commitment), `docs/rfc-information-flow.md` (headline research RFC), individual stub RFCs for the five other research directions.

## Why this document exists

The `intonaco`/`fresco` split RFC declares two non-negotiable theses:

1. **Compile-time-first**: when a property can be enforced at compile time, the substrate prefers compile-time over runtime
2. **Research drives engineering**: every substrate RFC ships theoretical contribution + engineering primitives + research artifact

This roadmap is the concrete program of work that operationalizes those theses. It identifies six research directions, each individually significant, each producing user-facing engineering primitives as derivatives, each contributing to a coherent compile-time-first reactive substrate.

The six are listed in implementation priority order, with rationale for ordering, prerequisite dependencies, and rough effort estimates.

## The six directions

### 1. Static information-flow analysis through the reactive graph

**Theoretical contribution**: information-flow type system layered on intonaco's static dependency graph (from `tracked:`). Signals carry trust labels (`Trusted[T]`, `Untrusted[T]`, custom labels for domain-specific taint). The reactive graph IS the dataflow graph; static analysis verifies that data with one label cannot reach a sink requiring a different label without passing through an authorized transformation.

**Engineering primitives that fall out:**
- `Signal[Untrusted[T]]` typed signals
- `sanitize[T](u: Untrusted[T]): T {.needs: SanitizerCap.}` declassification helper
- Compile-time `{.error: ...}` when untrusted data reaches a typed-trusted sink
- Domain-specific taint labels (e.g., PII tracking, secret tracking, user-input flow)
- **Static cycle detection** as a side product (the analysis traverses the graph; cycles are detected as a side-effect)
- **Dead-signal elimination** as a side product (signals with no reachable sinks can be flagged)

**Research artifact**: blog post / workshop paper on the unification of reactive dataflow graphs with information-flow type systems. The headline claim: prior IFC work assumes manual dataflow annotation; intonaco's `tracked:` provides the dataflow automatically, making IFC viable for general reactive programs.

**Why first**: highest leverage. Directly addresses AI agent / security-conscious UI use cases (prompt injection, untrusted tool-call inputs, PII propagation). Builds on `tracked:` which is already shipped. Subsumes static cycle detection (an obvious engineering win). The hardest of the six but unlocks the most.

**Prerequisites**: `tracked:` (shipped); type-level labels (small extension to the cap concept system); macro analysis of reactive transformations.

**Estimated effort**: 6 months full RFC + implementation. ~2000 LoC of substrate code + significant macro work + tests.

**RFC stub**: `docs/rfc-information-flow.md` (drafted in detail as the headline research RFC).

---

### 2. Effect / intent classification — three-axis static verification

**Theoretical contribution**: orthogonal three-axis classification of reactive code:
- **Capabilities** (authority — *what's this code allowed to do?*) — already shipped via the cap concept system
- **Effects** (observable interactions — *what does this code actually do?*) — pure / signal-read / signal-write / async-suspend / IO / blocking. Inferred by macro analysis of the body, statically verifiable.
- **Intent** (purpose — *what is this code trying to accomplish?*) — render / decide / fetch / mutate / audit / supervise. User-declared, machine-checked for consistency with inferred effects.

Static verification: the macro proves that declared intent matches inferred effects (a `render` intent doesn't mutate; a `pure` intent doesn't suspend; etc.).

**Engineering primitives that fall out:**
- `{.effect.}` pragma declaring intent
- Compile-time verification of intent vs effects
- Specialized notification dispatch for pure computations
- Effect deduplication (identical effects merge into one observer)
- Static "this is pure" proofs usable for memoization

**Research artifact**: Koka-style effect inference adapted to reactive substrate. Paper claim: prior effect systems assume sequential code; reactive systems have *temporal* effects (signal writes propagate to observers eventually). Effect classification must account for the propagation.

**Why second**: builds on the type-level infrastructure from (1). Unifies caps + effects + intent into one substrate. Provides the static foundation that (3), (4), and (6) all consume.

**Prerequisites**: information-flow substrate (1) provides the type-level extension machinery.

**Estimated effort**: 4 months. ~1500 LoC + macro work + tests.

**RFC stub**: `docs/rfc-effect-classification.md` (stub).

---

### 3. Linear / affine capability tokens

**Theoretical contribution**: lift the cap concept system from "Boolean" (you have it or you don't) to **substructural** (you have it N times, or once, or it must be consumed). Borrows from Rust's affine types and from linear logic. Compile-time tracking of cap usage count.

**Engineering primitives that fall out:**
- `cap MyCap, cardinality = Linear` — must be used exactly once
- `cap MyCap, cardinality = Affine` — may be used at most once
- `cap MyCap, cardinality = Bounded[N]` — may be used up to N times
- One-time deploy tokens, transactional resource handles, single-shot speculative scopes — all statically verifiable
- Rate-limited API call budgets verified at compile time

**Research artifact**: paper on substructural capability typing in a reactive substrate. Connection to Rust's ownership; novelty in applying to dynamic-cardinality scenarios (Bounded[N] with runtime N).

**Why third**: builds on (2)'s effect machinery (consumption is an effect kind). Provides the static-resource-management story that some research directions (especially observability + rewriteable history) want.

**Prerequisites**: effect classification (2).

**Estimated effort**: 3 months. ~800 LoC + macro work + tests.

**RFC stub**: `docs/rfc-linear-caps.md` (stub).

---

### 4. Type-level temporal invariants

**Theoretical contribution**: signals carry temporal invariants at the type level:
- `Monotonic[int]` — value never decreases
- `Bounded[int, 0..100]` — value stays in range
- `EventuallyConsistent[Pair[A, B]]` — A and B agree within K events
- `StableWithin[ms]` — value doesn't change more than once per K milliseconds

Compile-time verification: every write to such a signal preserves the invariant. Goes beyond Rust's type-level constants (static) to dynamic-value invariants tracked through the reactive graph.

**Engineering primitives that fall out:**
- Provably-monotonic counters
- Provably-clamped progress indicators
- Provably-bounded rate limiters
- Static stability proofs for UI (no flicker invariant)
- **Static cycle detection** as a side product (cycles in invariants are detectable)

**Research artifact**: TLA+-style temporal logic adapted to compile-time-checked reactive signals. Paper claim: temporal logic for reactive systems is usually runtime-verified (TLA+ trace checking, runtime assertion frameworks); doing it at compile time over the type system is novel.

**Why fourth**: builds on (1)'s information-flow infrastructure (invariants are flow constraints over time). Could plausibly precede (2)/(3) if a strong consumer use case appears.

**Prerequisites**: information-flow (1) for the type-level machinery.

**Estimated effort**: 4 months. ~1200 LoC + macro work + tests.

**RFC stub**: `docs/rfc-temporal-invariants.md` (stub).

---

### 5. Static UI completeness proofs

**Theoretical contribution**: given the reactive graph and the typed state model, prove at compile time:
- **Exhaustiveness**: for every state variant, some binding renders it
- **Reachability**: every binding is reachable from some user input or external event
- **Liveness**: bindings whose preconditions hold will eventually render
- **Determinism**: same input sequence produces same render output (given the journal)

Like exhaustiveness checking for `case` statements, generalized to the reactive UI graph.

**Engineering primitives that fall out:**
- Compile error when a state variant has no binding
- Compile error when a binding is dead
- Compile-time liveness proofs for critical UI paths
- Journal-based determinism verification

**Research artifact**: connection to academic reactive frameworks (Concur, FRP papers) that proved similar properties but never shipped as usable libraries. Paper claim: practical UI completeness checking at the language level, with the reactive substrate providing the necessary structural information.

**Why fifth**: touches both intonaco (verification) and fresco (rendering — the UI graph being verified is fresco-side). Builds on effect classification (2) — the "render" intent + UI graph is the verification target.

**Prerequisites**: effect classification (2). Benefits from temporal invariants (4) for liveness proofs.

**Estimated effort**: 5 months. ~1500 LoC + macro work + tests. Bridges intonaco and fresco; substantial coordination across the package boundary.

**RFC stub**: `docs/rfc-ui-completeness-proofs.md` (stub).

---

### 6. Reactive ABI stability checking

**Theoretical contribution**: a fresco / intonaco program (or library) declares a *reactive surface* — its set of public signals, their types, the bindings/effects users can attach. ABI compatibility is statically verifiable: V2 of a library is backward-compatible with V1 if every V1 consumer's bindings still type-check against V2's surface.

Like semver but actually verified rather than human-declared.

**Engineering primitives that fall out:**
- `reactiveAbi:` macro declaring a public reactive surface
- Compile-time backward-compatibility checking when comparing two ABI declarations
- Plugin system support (plugins declare what they touch; host verifies)
- Multi-process versioning (IPC contracts between processes)

**Research artifact**: paper on reactive-graph ABI stability. Most ABI work targets function signatures; reactive ABI is novel because the unit of stability is a reactive-graph node and its observers.

**Why last**: builds on everything else. The reactive surface includes signals (1), effects (2), caps (3 + 2), temporal invariants (4), UI completeness (5). Stable ABI requires stable definitions of all these things.

**Prerequisites**: ideally all five other directions, though a partial implementation could ship earlier with future-extension hooks.

**Estimated effort**: 4 months. ~1000 LoC + tooling for compatibility checking + tests. Less new substrate, more "synthesize across the existing substrate."

**RFC stub**: `docs/rfc-reactive-abi.md` (stub).

---

## Phasing and dependencies

```
                 ┌─────────────────────────────────────┐
                 │  1. Information-flow                │
                 │     (subsumes static cycle detect)  │
                 └──────────────────┬──────────────────┘
                                    │
                ┌───────────────────┼───────────────────┐
                │                   │                   │
                ▼                   ▼                   ▼
       ┌────────────────┐  ┌────────────────┐  ┌────────────────┐
       │ 2. Effect      │  │ 4. Temporal    │  │ (other future) │
       │    classification │    invariants  │  │                │
       └────────┬───────┘  └────────┬───────┘  └────────────────┘
                │                   │
                ▼                   │
       ┌────────────────┐           │
       │ 3. Linear caps │           │
       └────────┬───────┘           │
                │                   │
                ▼                   ▼
       ┌─────────────────────────────────────┐
       │ 5. UI completeness proofs           │
       │    (bridges intonaco + fresco)      │
       └──────────────────┬──────────────────┘
                          │
                          ▼
                 ┌─────────────────────────┐
                 │ 6. Reactive ABI         │
                 │    (synthesizes all)    │
                 └─────────────────────────┘
```

**Hard dependencies** (you can't ship the bottom without the top):
- (2) needs (1)'s type-level extension machinery
- (3) needs (2)'s effect substrate
- (4) needs (1)
- (5) needs (2), benefits from (4)
- (6) ideally needs all five

**Soft dependencies** (you can ship in parallel but coordination helps):
- (4) and (2)/(3) can run in parallel after (1)
- (5) can start once (2) is well-defined even if (3) and (4) are still in flight

**Recommended cadence**: one major research RFC every 4–6 months, parallel with surface engineering work on fresco (driver abstraction, widget library, layout system, etc.). Total roadmap: roughly 2–3 years.

## Surface engineering work in parallel

The research roadmap doesn't replace the surface engineering work. In parallel with the six research directions, the following ship as pure engineering RFCs:

- **Driver abstraction** (terminal / headless / web / file) — completes the intonaco/fresco split's promise
- **Widget library** (DataTable, Tree, OptionList, Form, MarkdownViewer, TextArea) — Textual-tier widget coverage
- **Layout system upgrade** (flex / grid / constraint-based) — beyond vstack/hstack
- **Transient interaction DSL** (`prompt`, `ask`, `confirm`) — one-liner ergonomics
- **Styling layer** (reactive themes + Style records)
- **Documentation site** + public docs (public adoption depends on this)

These are not research-driven. They're engineering investments fresco-the-library needs to be production-grade. They run independently of the research roadmap and don't gate on it.

## Cross-cutting principles

These apply to every research direction:

### Compile-time-first

When a property can be enforced at compile time, the implementation enforces it at compile time. Runtime checks are fallbacks for genuinely dynamic cases (e.g., a cap value provided by user input must be checked at runtime; everything else is static).

### Engineering primitives ship with theory

Every research RFC has a section enumerating user-facing primitives. The engineering audience can read just that section and adopt the primitives without understanding the theory.

### Research artifact accompanies each RFC

Blog post minimum; paper/talk preferred. Articulates the theoretical contribution to the academic audience.

### Validation by example

Each research direction includes an example consumer that exercises the new substrate. The information-flow RFC includes an "untrusted user input → tool call" example; effect classification includes a "pure computation memoization" example; etc. The example becomes a tutorial, a regression test, and a marketing artifact.

### Cross-direction coherence

The six directions are designed to compose. An information-flow-typed signal that's also temporal-invariant-tagged and effect-classified is a coherent multi-axis typed value, not a layered mess. RFC design checks for compositional cleanliness before commitment.

## What 1.0 means for intonaco

Per the split RFC's two-track 1.0 criterion, intonaco 1.0 requires:

- Cap system stable (no rewrites — μb shipped)
- Observability substrate landed (RFC complete, phases 1-3 shipped)
- **At least direction (1) of this roadmap landed** — information-flow as the headline compile-time-research contribution

Directions (2)–(6) are post-1.0 work. 1.0 represents "the substrate is research-grade, but only the foundational research direction has shipped; the rest are roadmapped."

This is the analogue of how LLVM 1.0 shipped with the basic SSA compiler infrastructure but not every subsequent optimization pass. The 1.0 commitment is to the architecture and the foundational research; later releases extend.

## Why six directions instead of three or twelve

Six is the natural set when you audit *what intonaco specifically enables that other reactive runtimes cannot*. Each direction requires intonaco's substrate to be possible:

- (1) needs the static reactive graph (`tracked:`)
- (2) needs effect inference machinery + the cap substrate
- (3) needs the cap substrate
- (4) needs the type-level extension machinery
- (5) needs the UI rendering + reactive substrate
- (6) synthesizes all of the above

A different reactive library would have different research directions because its substrate enables different things. Six is what intonaco's specific affordances support.

Fewer than six leaves load-bearing directions unbuilt. More than six dilutes focus; the additional directions would be either repackagings of these six or genuinely new substrates that should be their own roadmap.

## Adoption pattern

Each research RFC produces:

1. A new module in intonaco (e.g., `intonaco/flow` for information-flow)
2. New macros and type-level machinery
3. New cap tokens or concepts
4. Updated docs / tutorials
5. Example consumer in `examples/`
6. Blog post / research artifact
7. Regression test suite that pins the theoretical claim

Existing intonaco consumers can opt in to new research substrates incrementally. None of the six is *required* — a consumer can use intonaco's base reactive substrate without any research extensions. The extensions add safety/optimization properties for consumers that choose to engage with them.

## Decision log

(Empty initially. Decisions made during implementation get appended.)
