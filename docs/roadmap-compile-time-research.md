# Roadmap: compile-time-first research substrate

**Status**: Active roadmap (rebuilt 2026-05-23 after an honest pass — see "Rejected / superseded directions")
**Author**: Corey Leavitt
**Companion to**: `docs/rfc-intonaco-fresco-split.md` (the identity & structural commitment), `docs/rfc-consistency-model.md` (lead research RFC), and the per-direction RFCs.

## Why this document exists

The `intonaco`/`fresco` split RFC declares two non-negotiable theses:

1. **Compile-time-first**: when a property can be enforced at compile time, the substrate prefers compile-time over runtime.
2. **Research drives engineering**: every substrate RFC ships a theoretical contribution + engineering primitives + a research artifact.

This roadmap operationalizes those theses. It identifies **five research directions** plus a **shared analysis platform**, each riding on intonaco's static dependency extraction.

The selection bar (applied honestly, after a first cut that didn't survive scrutiny):

- **Pushes the reactive-substrate space forward** — *novel, OR currently lacking in reactive substrates with research-grade depth available.* Porting a mature framework into a substrate that lacks it is legitimate, provided there's real depth to mine.
- **Leverages Nim-specific features** — typed macros, concepts, `effecttraits`, `static[T]`, `distinct T`, custom pragmas, ORC/ARC. If it would be equally easy elsewhere, it isn't pulling Nim's weight.
- **Compile-time safety as the discipline** — runtime checks are the fallback, not the spec.
- **No security theater, no false sense of security** — we do not ship flashy features that are mostly useless or that imply guarantees the substrate can't honor.

## The shared platform

All five directions ride on **one walk**: the `tracked:` typed-macro walker that extracts the static dependency graph. The same descent yields, by different projections:

- dependency edges (scheduling — already shipped)
- topological heights and SCCs (consistency, productivity)
- consumption multisets (substructural)
- write-site enumeration (refinement)
- recursion structure (productivity)

**Building five separate analysis passes would defeat the entire thesis.** Each direction extends the walker's labelling function; none introduces a parallel traversal.

### The meta-thesis (the genuinely all-CS-novel contribution)

> **The typed reactive AST is a compile-time analysis platform.** A family of substrate properties — compile-time glitch-free scheduling, substructural discipline, refinement invariants, guarded productivity — is statically decided from one walk over the reactive graph. The platform claim is the novel meta-contribution; the individual analyses are honest substrate-gap ports with research-grade depth.

This replaces the abandoned "Reactive Coincidence Schema" framing, which was anchored to information-flow control — a direction we cut (see below).

**Note (2026-05-23, consistency RFC round 5):** direction 1 schedules the **statically-resolvable fragment at compile time** (the differentiator) and falls back to a runtime scheduler for the dynamic tier (collections, conditional reads). Round 3 briefly cut the compile-time tier on a soundness bug in a *global-table* mechanism; round 5 restored it via a sound *compositional per-site* mechanism (pending engine re-vet of the Nim mechanics). So glitch-free scheduling is a member of the statically-decided family — for the resolvable fragment — exactly as the platform thesis claims.

## The five directions

### 1. Formal consistency model for reactive updates — **LEAD**

**Gap**: every mainstream reactive substrate has a *runtime* glitch-free scheduler; **none decides scheduling at compile time**, and intonaco has no glitch-free scheduler at all today. **Depth**: **compile-time glitch-free scheduling** of the statically-resolvable fragment (the differentiator — resolved compositionally per construction site, sound by construction) on top of a runtime scheduler for the dynamic tier, with a formally-proved observational-glitch-freedom + cross-propagation-quiescence guarantee spanning the verified static/dynamic seam, plus a corrected two-tier convergence algebra. Sits under every other direction (they all reason about when/in what order a derivation re-runs).

**RFC**: `docs/rfc-consistency-model.md` (full draft).

### 2. Reactive transaction model

**Gap**: reactive STM is essentially undone — no signals substrate offers user-delimited atomic regions with abort/commit/retry and isolation. **Depth**: isolation levels for *push-based* observation, and compositional commit under re-execution. **Foothold**: speculative scopes are already ~70% of this. Explicit scoped strengthening of the consistency model's implicit per-propagation atomicity.

**RFC**: `docs/rfc-reactive-transactions.md` (stub).

### 3. Substructural types under reactive re-execution

**Gap**: substructural typing (linear/affine/bounded caps) is absent from reactive substrates. **Depth**: classical substructural systems assume single execution; reactive derivations re-run, so *what does linearity even mean under multi-shot re-execution?* De-risked — the gap-level port stands even if the re-execution theorem doesn't.

**RFC**: `docs/rfc-substructural-reexecution.md` (stub).

### 4. Refinement types for reactive signals

**Gap**: refinement types over mutable reactive values don't exist in the substrate space. **Depth**: invariants (`Bounded`) and successive-value relations (`Monotonic`) that must hold across an *unbounded write sequence*, every write site discharged at compile time. (Honest core of the old "temporal invariants" stub; `EventuallyConsistent` moved to direction 1, `StableWithin` dropped as timing.)

**RFC**: `docs/rfc-refinement-types.md` (stub).

### 5. Guarded productivity for reactive derivations

**Gap**: guarded recursion / coinductive productivity is absent from reactive substrates. **Depth**: distinguish *productive* cyclic structures (animation clocks, streams that advance through a guard) from divergent ones — turning the consistency model's "no cycles allowed" into "exactly the productive cycles allowed." Promoted to flagship (not a mere component) because guardedness is a substantial type-theoretic contribution.

**RFC**: `docs/rfc-guarded-productivity.md` (stub).

## Phasing and dependencies

```
        ┌───────────────────────────────────────────┐
        │   Shared platform: the tracked: walker      │
        │   (heights · SCCs · consumption · writes)   │
        └───────────────────────┬─────────────────────┘
                                │
                                ▼
                ┌───────────────────────────────┐
                │  1. Consistency model (LEAD)   │
                │  compile-time glitch-free sched │
                └───────────────┬───────────────┘
                                │
        ┌───────────────┬───────┴───────┬───────────────┐
        ▼               ▼               ▼               ▼
┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│ 2. Trans-    │ │ 3. Substr-   │ │ 4. Refine-   │ │ 5. Guarded   │
│    actions   │ │    uctural   │ │    ment      │ │    product-  │
│ (foothold:   │ │ (re-exec     │ │ (write-site  │ │    ivity     │
│  speculative)│ │  semantics)  │ │  discharge)  │ │ (good cycles)│
└──────────────┘ └──────────────┘ └──────────────┘ └──────────────┘
```

**Hard dependency**: all four follow the consistency model — it defines re-execution count (consumed by 3), the cycle/SCC machinery (extended by 5), the write-site walk (consumed by 4), and the per-propagation atomicity that transactions (2) strengthen.

**Soft**: 2–5 can run in parallel once 1 lands; 2 and 3 want coordination (transaction boundary as consumption boundary); 1 and 5 want coordination (cycles-as-errors vs productive-cycles-allowed).

**Recommended cadence**: one major research RFC every 4–6 months, parallel with fresco surface engineering. Total roadmap: ~2 years for the five.

## Rejected / superseded directions

Recorded so the reasoning isn't re-litigated. (The killed RFCs were deleted 2026-05-23; git preserves them.)

- **Information-flow control (IFC) — KILLED.** Not for lack of novelty, for *falseness*: API-layer auth is the default and correct control point for data; substrate-layer IFC is downstream of the real control and provides either redundant checks or a false sense of security (labels the LLM/agent loop launders anyway). Prompt-injection, PII, and secret-token framings all failed the "where does the dangerous flow actually live?" test — it lives in the agent loop / data layer, not the reactive UI. No honest security story exists at the substrate layer.
- **Effect / intent classification (rows) — KILLED as a direction.** UI-shaped intent vocabulary (render/decide/mutate) with thin research value over Koka-style rows. The genuinely useful part — effect/dependency extraction — is **absorbed into the shared walker platform**, which every surviving direction consumes. The intent surface stays dead.
- **Reactive ABI stability — KILLED.** Engineering with known tools (semver, type-shape diff); no research depth to mine.
- **Static UI completeness proofs — MOVED to fresco.** Research-shaped but frontend-domain (the UI graph being verified is fresco-side), so it belongs in fresco's frontend research notes, not intonaco's substrate roadmap. `docs/rfc-ui-completeness-proofs.md` retained as a fresco-side note.

## Surface engineering work in parallel

Unchanged by the research rebuild. In parallel with the five directions, these ship as pure engineering RFCs and don't gate on the research:

- Driver abstraction (terminal / headless) — completes the split's promise
- Widget library (DataTable, Tree, OptionList, Form, MarkdownViewer, TextArea)
- Layout system upgrade (flex / grid / constraint-based)
- Transient interaction DSL (`prompt`, `ask`, `confirm`)
- Styling layer (reactive themes + Style records)
- Documentation site + public docs

## Cross-cutting principles

### Compile-time-first
When a property can be enforced at compile time, the implementation enforces it there. Runtime checks are fallbacks for genuinely dynamic cases.

### Engineering primitives ship with theory
Every RFC enumerates user-facing primitives; the engineering audience can adopt them without the theory.

### Research artifact accompanies each RFC
Blog post minimum; paper/talk preferred.

### Validation by example
Each direction ships an example consumer that exercises the new substrate — tutorial, regression test, and artifact in one.

### Cross-direction coherence
The five compose: a signal can be glitch-free-scheduled, transaction-scoped, cardinality-tracked, refinement-typed, and productivity-checked as one coherent multi-axis value, not a layered mess. RFC design checks compositional cleanliness before commitment.

## What 1.0 means for intonaco

Per the split RFC's two-track 1.0 criterion, intonaco 1.0 requires:

- Cap system stable (μb shipped)
- Observability substrate landed (phases 1–3)
- **At least direction (1) — the consistency model — landed**, as the foundational compile-time-research contribution that the rest build on.

Directions (2)–(5) are post-1.0. 1.0 means "the substrate is research-grade and the foundational direction has shipped; the rest are roadmapped." (Analogue: LLVM 1.0 shipped the SSA infrastructure, not every later pass.)

## Adoption pattern

Each research RFC produces: a new intonaco module, new macros/type-level machinery, new caps/concepts, updated docs, an `examples/` consumer, a research artifact, and a regression suite pinning the theoretical claim. All five are opt-in — a consumer can use intonaco's base reactive substrate with none of them.

## Decision log

- **2026-05-23** — Rebuilt the roadmap from six directions to five + shared platform. Killed IFC (security theater; API auth is the correct layer), effect/intent rows (absorbed useful part into the platform; intent surface dead), and reactive ABI (engineering, not research). Moved UI completeness to fresco. Promoted a new lead — the consistency model (compile-time glitch-freedom) — and added the reactive transaction model and guarded productivity as flagships. Re-scoped linear caps → substructural-under-re-execution and temporal invariants → refinement types. Dropped the IFC-anchored "Reactive Coincidence Schema" meta-thesis in favor of "typed reactive AST as a compile-time analysis platform."
