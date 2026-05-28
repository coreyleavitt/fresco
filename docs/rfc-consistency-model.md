# RFC: Compile-time glitch-free scheduling for the reactive substrate

**Status**: Active — shipped and machine-checked. The C-shape direction is live (intonaco milestone #3, `intonaco/docs/rfc-c-shape-migration.md`); the runtime scheduler is unchanged and Lean-proven.
**Author**: Corey Leavitt
**Companion to**: `docs/roadmap-compile-time-research.md`, `docs/rfc-intonaco-fresco-split.md`, `intonaco/docs/rfc-c-shape-migration.md`

## Thesis

intonaco schedules its reactive graph **glitch-free**, with the schedule **decided at compile time** for every binding in the static fragment — a property no mainstream reactive substrate has (Solid, MobX, Vue, Reactively all maintain glitch-freedom *dynamically*, at runtime). Compile-time scheduling is the **forced default**: every binding declares its dependencies syntactically; heights compose at compile time; the walker rejects undeclared reactive reads at sem time; and an explicit, type-quarantined escape (`Dynamic[T]`) handles patterns that are genuinely dynamic. `intonaco` is the product; `fresco` is one consumer and a strict-mode proof-of-discipline, **not** a design constraint.

## The model

### Runtime worklist scheduler — the sound floor

Propagation is a height-ordered drain, not recursion. `Computation` carries `height: int` and `inQueue: bool`; dispatcher-local state (`gPropagating`, `gQueue`) drives it. `notify` enqueues observers; a nested `set`→`notify` during a `run()` enqueues instead of recursing because `gPropagating` is set; the drain pops minimum height. A node only fires after every lower-height dependency has settled — **glitch-free by construction**. The scheduler is sound regardless of how heights got assigned. (`src/intonaco/reactive/subscribable.nim`.)

Production form (per engine review): a bucketed `seq[seq[Computation]]` keyed by height (heights are small dense ints) beats a heap; reuse buckets across propagations; `{.push checks:off.}` on the drain. A ≤1-observer fast path keeps the common linear case allocation-free.

### Compile-time height resolution — explicit deps, structural soundness

Each binding declares its dependencies in a bracket:

```nim
signals:
  count = 0           # bakes {.height: 0.} on `count`
  title = ""

computed doubled, [count]:
  count * 2           # height = 1 + max(heightOf(count)) = 1; baked as {.height: 1.}

computed label, [count, doubled, title]:
  title & ": " & $count & " (" & $doubled & ")"   # height = 1 + max(0,1,0) = 2

effect [label]:
  paint(label)         # height = 3
```

Compile-time mechanism (`src/intonaco/reactive/height.nim` + `binding.nim`):

- `heightOf(sym): Option[int]` reads the `{.height: N.}` pragma off the binding's identdef via `getImpl` + `eqIdent` (NOT `getCustomPragmaVal`, which silently fails across a macro's `typed`-param boundary).
- `composeHeight(deps): Option[int]` = `Some(1 + max(heightOf d for d in deps))`, propagating `none` if any dep is unresolvable. The static fragment is **downward-closed** by construction.
- `withHeight(name, h)` bakes the result as `{.height: N.}` on the new binding so downstream `computed`s compose through it. Cross-module: the pragma rides Nim's `.nim` serialization.

Under `-d:intonacoStrict`, an unbaked dep is a **hard compile error**.

### The body walker — sem-time safety net

Inside a binding's body, the dep names are shadowed as their snapshot values (`count` is `int`, not `Signal[int]`). The walker (`noUndeclaredSignals`, `binding.nim`) then rejects three patterns at sem time, all caught by walking the typed AST:

1. **Direct undeclared reactive read.** Any `nnkSym` of type `Signal[_]` or `Dynamic[_]` remaining in the body. Since the declared deps were shadowed to plain values, any remaining reactive-typed sym IS by construction an undeclared read.
2. **Transitive read via helper.** Any call whose callee carries `ReactiveRead` (Nim `tags` effect on `Signal.get`/`Dynamic.get`) and isn't an untracked accessor (`peek`). Effect propagation surfaces transitive reads through pure-looking helper procs.
3. **Opaque callee.** Any call whose callee has `RootEffect` (method dispatch / async / FFI without `{.effectsOf.}` / indirect call through a value sym) — the compiler couldn't see through it. Allowed only if the callee carries `{.forbids: [ReactiveRead, ReactiveWrite].}`.

The walker IS the soundness net: explicit deps guarantee correct heights *if and only if* the body's read-set is contained in the declared deps, which is exactly what the walker enforces.

### Cross-tier: `Dynamic[T]` as the type quarantine

The dynamic tier (`src/intonaco/reactive/dynamic.nim`) is for patterns the static fragment legitimately can't express:

- A signal chosen at runtime (`sigs[idx()]`).
- A collection of signals whose membership changes (`CollectionSignal[T]` + `each`).
- A conditional mount (`mountWhen(boolSig): body`).

The escape is **type-quarantined**: `dynamicComputed` returns `Dynamic[T]`. A static binding declaring `Dynamic[T]` as a dep has no `{.height.}` pragma to read → `composeHeight` returns `none` → under strict, hard compile error; otherwise the binding falls to runtime height accumulation. The walker also rejects any `Dynamic[_]`-typed sym in a static body's typed AST.

The dynamic tier has its own macros: `dynamic name: body` (single-value), `each item in coll: body` (collection iteration with per-item scope lifecycle), `mountWhen(boolSig): body` (conditional mount). All compose onto the same runtime scheduler — the dynamic-tier nodes accumulate heights at subscribe time; the cross-tier monotonicity invariant (`(★) h(v) > h(u)` for every edge `u→v`) is preserved.

### Strict gate

`-d:intonacoStrict` forbids the silent fallback path: an unbaked dep, a non-baked source, or any walker-rejected read is a compile error. The probes (`intonaco/tests/test_binding_strict_{ok,fail}.nim`) verify the gate fires exactly where it should.

## The guarantee

Single height function over all nodes (static = baked constant, dynamic = runtime-accumulated). `A` = atomic least-fixpoint oracle; `H` = the height-ordered drain. Machine-checked in `intonaco/proofs/Consistency.lean` (Lean 4, **mathlib-free, sorry-free, axiom-clean** — only `propext`, `Quot.sound`, `Classical.choice`):

- **`confluence`** (Lemma 1). `H` and `A` reach the same final store. *Induction on height over the DAG.*
- **`glitchFree`** (Lemma 2). Only effects observe intermediate state. Every node fires only after all lower-height deps are final.
- **`lemmaB`** (cross-tier monotonicity). Invariant `(★)` holds across the static/dynamic seam. Baked static heights are fixed witnesses; dynamic heights accumulate as `1 + max(deps)`.
- **`heightOrderedCorrect`** + **`worklistCorrect`** — the **actual** min-height worklist algorithm (closes idealized-vs-real).
- **`overApproxSound`** (the C-shape victory). `readset ⊆ D ∧ (∀d∈D, trueHeight d ≤ heightOf d) ⟹ maxSucc trueHeight readset ≤ 1 + maxSucc heightOf D`. Under the explicit-deps shape, **`D = readset = the declared deps trivially**; the precondition is satisfied by construction. The conclusion delivers *unconditionally* — the implication is no longer a leaky antecedent that has to be vouched at every binding.

### Exactly-once

For acyclic graphs each effect fires exactly once per settled change (regression-tested in `tests/test_diamond_glitch.nim`, `test_depth_and_backfeedback.nim`, `test_effect_feedback.nim`). Contractive cycles re-settle and terminate; non-contractive cycles are caught by a value-fixpoint divergence guard (a diagnostic backstop; real productivity is direction 5, `rfc-guarded-productivity.md`).

Assumptions: **A1** acyclic static graph (cycles → no glitch guarantee; productive cycles → direction 5). **A2** unresolvable dep → dynamic tier via `Dynamic[T]`. **A3** no mid-propagation graph mutation except speculative `rollback`, sequenced at propagation depth 0.

## The collection algebra

Incremental reactive collections on the same compile-time-scheduled substrate (`intonaco/src/intonaco/reactive/{collection,deltafloor,derive,scan,each}.nim`). A `CollectionSignal[T]` emits typed positional deltas (insert / remove / update / clear / replace + a batched speculative rollback), delivered through the height-ordered scheduler via per-consumer buffered `Computation`s (NOT eager fanout — eager glitched diamonds).

A closed algebra of **LINEAR** operators where `incremental == apply-to-delta` is sound by construction (DBSP's linear-operator theorem):

- **`derive name, c, f`** — map. `f` must be pure (walker-enforced).
- **`keep name, c, p`** — filter, with a source→view rank/index-translation.
- **`fold name, c, f`** — aggregate over a `CommutativeGroup` (see `convergence.nim`).

Plus **`scan name, coll, [extraDeps], initial, step`** — delta-stream fold. The mandatory `[extraDeps]` bracket lists every signal the step reads beyond the delta arg; heights compose as `max(coll.height+1, max(deps)+1)`; the walker fires on any uncovered reactive read in the step body.

The function arg's purity is the linearity boundary: a signal-dependent transform makes the operator **bilinear** (a join), deliberately out of scope. The walker catches this directly. **DBSP/Z-sets rejected** for the substrate: best-in-class for unordered incremental computation; wrong domain for ordered terminal UI.

**OPEN — the IVM-equivalence proof** (intonaco #74): mechanize `apply(view, op_delta(δ)) == op(apply(source, δ))` per `DeltaKind` for derive/keep/fold in `proofs/` (Lean, mathlib-free). map = the linear rule; keep = + the rank invariant; fold = the group laws. Shape consumer-validated; no changes pending.

## Developer experience — a substrate contract

DX is defined by the substrate; only *rendering* is a frontend concern. `intonaco/src/intonaco/verification.nim` owns the diagnostic contract:

```nim
type
  Severity* = enum sevSilent, sevNote, sevError
  GlossaryTerm* = enum                       # an un-glossaried term is a compile error
    gtReactiveCycle, gtSafeMerge, gtValueRule, gtUsedMoreThanAllowed, ...
  Diagnostic* = object
    severity*: Severity
    symptom*: string; site*: SourceSite; rule*: GlossaryTerm; fix*: string
    breaksPreconditionOf*: seq[SignalId]; pausedBy*: Option[DiagnosticId]
```

Internal vocabulary (`height`, `SCC`, the static/dynamic tier) **never** surfaces to developers — they see consequences ("could read a half-updated value", "this value depends on itself"), not proof internals. `validate(Diagnostic)` rejects internal tokens outside an explicit expert channel. Diagnoses are tiered by *developer consequence* and grouped root-cause-first across signals (a structural error pauses downstream checks rather than emitting a cascade). `-d:intonacoStrict` gates "zero runtime fallbacks" in CI. Any *rendering* (a terminal devtools panel, a sinopia trace view) is a frontend's job, not the substrate's.

## Nim leverage — the standard

The substrate uses Nim's hard-but-powerful features rather than retreating to easier ones, because abstracting that difficulty away from the end user is the point of the library:

- **Typed macros** with the outer-untyped / inner-typed two-stage pattern for the binding macros (homogenizes the deps bracket so heterogeneous `Signal[T]` element types pass through Nim's type-unification; lets the body's existing references re-resolve to the shadow `let`s).
- **The effect system** (`ReactiveRead` / `ReactiveWrite` tags + `std/effecttraits` + `{.effectsOf.}`) for **transitive read detection in the walker** — `getTagsList` propagates `ReactiveRead` through every helper that reads a signal, regardless of nesting depth. `{.forbids.}` is surgically precise (catches subtypes but not the `RootEffect` supertype).
- **Custom-pragma value round-trip across modules** for the height carrier (with the `getImpl`+`eqIdent` workaround for the `getCustomPragmaVal` typed-param bug).
- **Compile-time VM** for the walker, height composition, and macro-time pragma reads.
- **ORC** deterministic destructors + `{.nocursor.}` pins for the scheduler's hot path (e.g. `unsubscribeAll`'s `var alive = c`).
- **`{.push checks:off.}`** on the proven-safe drain loop.

"This Nim feature is hard / experimental" is not a valid reason to avoid the correct tool.

## What's shipped (commit-traced)

Substrate (intonaco main, then c-shape branch via milestone #3 atomic merge):

| Direction | Commit / file |
|---|---|
| Height-ordered worklist scheduler | `subscribable.nim` (`989a7e4`, intonaco#48) |
| Effect-tagged signal reads / writes + `forbids` levers | `subscribable.nim` types (`1fb0da0`, intonaco#49) |
| Compile-time height carrier | `height.nim` (`007eea5`, intonaco#51) |
| C-shape binding layer (`computed` / `effect` + walker) | `binding.nim` (milestone #3 / M1) |
| Dynamic tier (`Dynamic[T]`, `dynamic` macro, `each`, `mountWhen`) | `dynamic.nim` + `each.nim` + `task/mount.nim` |
| Collection algebra (derive / keep / fold / scan) | `derive.nim`, `scan.nim`, `deltafloor.nim` |
| Diagnostic contract | `verification.nim` (`7e0f47a`, intonaco#55) |
| Convergence concepts (commutative-monoid / joinable + law witness-checks) | `convergence.nim` (`888cbb2`, intonaco#54) |
| Mechanized proof | `proofs/Consistency.lean` — `lemmaB`, `confluence`, `glitchFree`, `heightOrderedCorrect`, `worklistCorrect`, `overApproxSound`, `linearOpStatLaw`, `maxSucc_mono_{subset,height}` |

## Open

1. **IVM-equivalence proof** for the collection algebra (intonaco#74) — mechanize `apply(view, op_delta(δ)) == op(apply(source, δ))` for derive/keep/fold in Lean.
2. **Dynamic-tier proof** (intonaco#61) — mechanize the runtime floor's glitch-freedom. Same scheduler underneath, but the runtime accumulation path's correctness deserves its own theorem.
3. **Propagation-identity token + serialize-vs-merge scheduler integration** (intonaco#60) — multi-threaded dispatch; v3 design item.
4. **Cross-module diamond glitch test** (intonaco#72) — empirically validate cross-module composition of baked heights (currently sound-by-construction but unexercised empirically).
5. **Explicit stance on cycles** (intonaco#73) — compile-time rejection or documented no-glitch-guarantee precondition.

(Items 3–5 live in intonaco milestone #4, "Scheduler refinement-conformance harness" — shape-independent.)

## fresco conformance (downstream)

fresco's binding layer (`src/fresco/reactive/binding.nim`) is being rewritten on the C-shape substrate in **fresco milestone #10**. The work: rewrite `bindRow` / `bindRows` / `bindCollection` over `computed name, [deps]: body`; rewrite `devtools/panel.nim` with explicit-deps brackets; rewrite the integration tests. This is downstream conformance — its scope is **never** a reason to soften a substrate decision.

## Provenance

The consistency-direction (research lead, intonaco milestone #1) shipped through five PhD-tier review rounds + a build spike, then through a multi-round architecture review that re-examined the original auto-tracking-with-inference shape (the **A-shape**) against safety values, multi-frontend constraints, and ergonomic axes. The architecture review found the A-shape's safety contingent on Nim-effect-inference completeness (a perpetually-vigilant boundary), and the explicit-deps shape (the **C-shape**) structurally satisfied the safety claim — the over-approximation lemma's antecedent becomes true by construction rather than a leaky in-band check.

The transition is recorded in `intonaco/docs/rfc-c-shape-migration.md`. Both shapes used the same Lean proof, the same scheduler, the same height carrier, the same Dynamic[T] quarantine. What changed: the **mechanism** by which the dep set is determined — from inference (the deleted classifier + purity oracle + bail-first walk) to declaration (the explicit bracket + sem-time walker).

The lesson the migration encodes: when the inference whack-a-mole is the symptom, the question is whether the inference is necessary at all. Often, *declaration* delivers the same guarantee with a smaller trusted core and a structurally satisfied soundness condition.
