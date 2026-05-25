# RFC: Compile-time glitch-free scheduling for the reactive substrate

**Status**: Locked draft — **empirically validated by a build spike** (see "What's proven"). Supersedes the prior analysis-only draft. Implement per "Phasing".
**Author**: Corey Leavitt
**Companion to**: `docs/roadmap-compile-time-research.md`, `docs/rfc-intonaco-fresco-split.md`

## Thesis

intonaco schedules its reactive graph **glitch-free**, with the schedule **decided at compile time** for every statically-resolvable node — a property no mainstream reactive substrate has (Solid, MobX, Vue, Reactively all maintain glitch-freedom *dynamically* at runtime). Compile-time scheduling is the **forced default**, not an optional tier: the API steers every consumer toward statically-analyzable reactive code, falls back to a *sound* runtime scheduler where it must, and requires an **explicit, loud opt-in** for genuinely-dynamic patterns. This is a forcing function — the substrate leads; consumers conform. `intonaco` is the product; `fresco` is one consumer and a strict-mode proof-of-discipline, **not** a design constraint.

## What's proven (build spike, 2026-05-24)

Every load-bearing claim below traces to a passing test against the live substrate — not analysis. Now **committed in the intonaco repo**: scheduler (`989a7e4`), standalone test harness (`6b7d9d8`), `SignalRead`/`SignalWrite` effects (`1fb0da0`). Scheduler regression in `tests/test_{diamond_glitch,depth_and_backfeedback,effect_feedback}.nim` (run by `nimble test`); effect/FFI evidence in `tests/spike_{effecttraits,ffi_detect,setraw_verify}.nim`.

- **The substrate glitches today.** Eager depth-first `notify` fired a diamond's apex on a mixed-version `(b≠c)` state, twice per write. *(test_diamond_glitch, RED against unmodified substrate.)*
- **A height-ordered worklist fixes it — and restores exactly-once.** ~30-line change (height/kind/inQueue on `Computation`, subscribe-time height accumulation, `notify` as a min-height drain). Glitch gone; apex fires exactly once. *(test_diamond_glitch, GREEN.)*
- **Regression-clean.** Full fresco suite (569 tests) passed under the rewritten `notify` — speculative, journal, time-warp, animation, collection, context-across-await, supervisor, devtools. *(exit 0.)*
- **Scales to depth.** Depth-4 stacked diamonds stay glitch-free and exactly-once at the height-4 apex; wide diamonds too. *(test_depth_and_backfeedback.)*
- **Effect-feedback needs no special machinery.** Forward chains, contractive self-feedback (runs to quiescence + terminates), and backward writes (re-settle correctly) all work under a *uniform* enqueue model with **no deferred-write distinction**. *(test_effect_feedback + test_depth_and_backfeedback.)* → the deferred-write / cross-propagation-quiescence design is **cut** (see below).
- **The compile-time classifier is soundly achievable — and soundness is load-bearing.** A pattern-taxonomy classifier resolves direct / multi / formatter-wrapped / conditional reads as STATIC and correctly excludes alias / runtime-keyed / hidden-global reads as DYNAMIC. *But* a naive first cut silently misclassified `sigs[1]()` and a hidden-global read as STATIC — the exact "too-low height → silent glitch" failure — and took two detection fixes to close. *(test_fragment_classifier, in fresco.)*
- **Effect-tagging works as the classifier's purity gate (#49).** `SignalRead` on `get` → zero breakage on the 569-test corpus; `getTagsList` gives transitive + `effectsOf`(HOF) detection; `peek` correctly excluded. `SignalWrite` injected via a pure `setRaw` (set itself can't carry an upper-bound tag — it journals + propagates). `{.forbids:[SignalRead/SignalWrite].}` enforce and are surgically precise (the `RootEffect` supertype doesn't trigger them). *(spike_effecttraits, spike_setraw_verify.)*
- **FFI is forceable, not silently opaque (#49).** `effectsOf` composes with `importc` (callback reads propagate); an `importc` proc with a callback param but no `effectsOf` is detectable at compile time via `getImpl` → the classifier forces annotation (error in strict) rather than assuming purity. *(spike_ffi_detect.)*

## The model

### Runtime worklist scheduler — the sound floor

Propagation is a height-ordered drain, not recursion. `Computation` gains `height: int` and `inQueue: bool`; dispatcher-local state (`propagating`, the queue, a dirty-set) drives it. `notify` enqueues observers; a nested `set`→`notify` during a drained `run` enqueues (instead of recursing) because `propagating` is set; the drain pops min-height. A node only fires after every lower-height dependency has settled — glitch-free by construction. This floor is **sound regardless of what the classifier can prove**, which is what makes Architecture B safe.

Production form (per the engine review): a bucketed `seq[seq[Computation]]` keyed by height (heights are small dense ints) beats a heap; reuse buckets across propagations; `{.push checks:off.}` on the drain; `{.nocursor.}`-pin the running node across `run()` (it can `unsubscribeAll` itself and drop the last ref). A ≤1-observer fast path keeps the common linear case allocation-free.

### Compile-time height resolution — the forced default

Each `createComputed`/`createEffect` resolves its height at its own expansion, compositionally: `height = 1 + max(dependency heights)`, where each statically-resolved dependency's height is read from a `{.height: N.}` custom pragma on its symbol. Declaration-before-use guarantees a dependency expanded (and has its height) before its dependent — so there is no global table and no completeness assumption. Carrier rules (engine-validated by compiled spikes):

- Read the pragma via **`getImpl(sym)[0][1]` + `eqIdent`**, *not* `getCustomPragmaVal` (which silently fails across the macro `typed`-param boundary — a `macros.nim` symbol-identity bug).
- **Cross-module via the exported symbol's pragma** (rides `.nim` serialization). `macrocache` does *not* cross modules; `static[int]` type-params would infect the public `Signal[T]` surface. The pragma is the only carrier that's both sound and cross-module.

### The classifier — built on Nim's effect system

The classifier answers two questions about a reactive body. **Which named signals does it read directly, and at what heights?** — answered by an AST walk (the specific dependency + height extraction). **Could any call in the body *hide* a signal read?** — answered by **Nim's effect system, not a hand-rolled AST descent.**

A signal read is a tracked effect: `SignalRead = object of RootEffect`, with `Signal.get`/`()` tagged `{.tags: [SignalRead].}` — **not `peek`** (an untracked read creates no reactive dependency, so it must not count). Then `getTagsList(callee)` (via `std/effecttraits`) reports whether a call **transitively** reads a signal — the compiler computes the whole-call-graph closure and honors `{.effectsOf.}` for higher-order functions. Both verified (#49): a depth-2 helper shows `SignalRead`; `items.map(readingCb)` propagates via `effectsOf`. This is sound where a shallow `getImpl` descent is leaky — the descent misses transitive chains (`a()`→`b()`→`readsSignal()`) and HOFs.

**FFI is the one place the effect system is NOT conservative** (corrected from the earlier draft, which wrongly claimed it was): `getTagsList` returns `@[]` for an `{.importc.}` proc — it can't see the C body. So an unannotated FFI binding silently drops a callback's signal read. This is handled by *forcing*, not trusting (see "Effect tagging resolved" below), not by assuming FFI is pure.

The two compose: **AST walk for specificity (which signal, what height), effect system for the sound transitive purity gate.** A call whose `getTagsList` lacks `SignalRead` is a pure transform of its (already-resolved) arguments → the node stays STATIC. A call that transitively reads a signal not passed as an argument → the node is DYNAMIC.

*Soundness is the load-bearing obligation* (the spike's sharpest finding): a classifier that wrongly marks a hidden/indexed read STATIC bakes a too-low height and silently reintroduces the glitch the scheduler exists to prevent. The effect-system gate makes the transitive-purity half sound; the AST half must exhaustively detect Signal-typed receivers regardless of node kind (the spike's `nnkSym`-only check was a hole that let `sigs[1]()` leak).

### Effect tagging resolved (#49) — first-class effects, forbids levers, forced FFI

`SignalRead` and `SignalWrite` ship as **first-class, exported** effects (the experiment proved exposure is free — zero breakage across the 569-test corpus):

- **`SignalRead`** — tagged on `get`/`()`. Powers the classifier gate *and* a public lever: `{.forbids: [SignalRead].}` declares "this context must not read reactive state."
- **`SignalWrite`** — `set` can't carry it as a *declared* tag (it journals → `TimeEffect`/`RootEffect`, and propagates → arbitrary observer effects, so a `tags:[X]` upper bound blows out). Instead a pure `proc setRaw {.tags:[SignalWrite].} = s.val = v` carries it, and `setCore` routes its store through `setRaw` — a declared tag *injects* into callers, so everything calling `set` carries `SignalWrite`. Lever: `{.forbids: [SignalWrite].}` = "render can't mutate."
- **`forbids` is surgically precise** (verified): it rejects an effect and its *subtypes*, not the `RootEffect` *supertype*. So a proc carrying the catch-all `RootEffect` (which `set` does, via `notify`) is **not** falsely rejected by `forbids[SignalRead]`/`forbids[SignalWrite]` — the levers work in real, effect-laden code.

### Implemented: the purity oracle + effect firewall (#50, committed intonaco `4f0380a`)

`src/intonaco/reactive/purity.nim` — the reusable purity primitive the classifier (#52) and directions #4/#46 consume. Two queries:

- **`reactiveEffects(n): Reactivity{effects, opaque}`** — specific effects from `getTagsList` *plus* an `opaque` flag set when the compiler punted (bare `RootEffect`). Because the compiler emits `RootEffect` for **dynamic dispatch, async bodies, and indirect proc-value calls** alike (all verified), the `opaque` flag catches every punt-shape in one query — no per-shape blocklist to keep exhaustive.
- **`opaqueReactiveCalls(body, strict): seq[OpaqueCall]`** — the lone opacity `getTagsList` is *blind* to: FFI (`importc` → `@[]`). Contract-based: callback FFI needs `{.effectsOf.}`; no-callback FFI is trusted unless `strict` (← `defined(intonacoStrict)`), which requires a `{.forbids:[SignalRead,SignalWrite].}` vouch — closing the exotic hardcoded-`exportc` gap.

**The enabling substrate change — the effect firewall:** `{.cast(tags:[]).}` wraps `notify`'s observer dispatch (subscribable.nim) and `setCore`'s journal write (signal.nim). An observer's / the journal's effects are fired *by the scheduler/substrate*, not by the writing code — so they must not leak into a writer's inferred `tags`. Without it, every `set` carries `RootEffect` and the opacity signal is worthless. This is the *correct effect model* (a write's reactive effect is `SignalWrite`, full stop), and it's **inference-only — runtime is unchanged** (intonaco suite + 569-test fresco regression both green). Net: opacity is **sound by construction** (the compiler's own punt-signal + a strict FFI contract), not a maintained enumeration of call shapes.

**FFI is forced, not bailed.** Since `getTagsList` is blind to C bodies, the rule is: `effectsOf` composes with `importc` (verified — `proc cFn(cb) {.importc, effectsOf: cb.}` propagates the callback's reads), and an `importc` proc with a callback param but *no* `effectsOf` is **detectable at compile time** (`getImpl` exposes pragmas + params, verified). So the classifier *errors* on such a call inside a reactive body ("annotate `effectsOf` or wrap in `dynamic:`"), hard under `-d:intonacoStrict`, rather than silently treating it as pure. Non-callback FFI has no parameter path to a signal; the allowlist covers only the exotic C-hardcodes-a-Nim-`exportc`-reader residual. A binding-generator macro (or `softlink`) is the natural place to enforce/auto-add `effectsOf`.

### Architecture B — forced default, sound floor, explicit escape hatch

- **Static (the default):** classifier resolves the node → compile-time-baked height, zero runtime height bookkeeping.
- **Runtime fallback (the sound floor):** classifier can't resolve it (a formatter without descent reach, a conditional it conservatively widens) → the node gets a runtime height in the worklist, **with a warning** that names what defeated static resolution and how to restructure. Always correct; never silent.
- **`dynamic:` escape hatch (loud opt-in):** genuinely-unschedulable patterns (runtime-keyed `sigs[key()]()`, aliases, intentional graph-as-data) require an explicit `dynamic:` block. Possible, but visible and intentional — never a silent degrade.
- **`-d:intonacoStrict`:** promotes the warnings to hard errors — zero runtime fallbacks, pure compile-time scheduling. **fresco builds under strict** as the proof that the pure-static path is livable, without the substrate forcing strictness on other/future consumers.

The escape-hatch boundary is *measured*, not guessed — the spike taxonomy draws it: direct / multi / formatter / conditional → static; alias / runtime-keyed / hidden-global → `dynamic:`.

## The guarantee

Single height function over all nodes (static = baked constant, dynamic-tier = runtime). `A` = atomic least-fixpoint oracle; `H` = the height-ordered drain.

- **Lemma 1 (confluence).** `H` and `A` reach the same final store. *Induction on height over a DAG.*
- **Lemma 2 (observational glitch-freedom).** Only effects observe intermediate state (a pure computed's transient is overwritten before any read). Every node fires only after all lower-height dependencies are final.
- **Lemma B (cross-tier monotonicity).** Invariant `(★) h(v) > h(u)` for every edge `u→v`, with baked static heights as fixed witnesses and dynamic heights `1 + max(deps)`. Lemma 2 then holds across the static/dynamic seam.
- **Exactly-once.** For acyclic graphs each effect fires exactly once per settled change (proven by spike — this is the *stronger* guarantee, recovered by cutting the deferred-write machinery). Contractive cycles re-settle and terminate; non-contractive cycles are caught by a value-fixpoint divergence guard (a diagnostic backstop; real productivity is direction 5).

Assumptions: A1 acyclic static graph (cycles → compile error; productive cycles → direction 5). A2 conditional/unresolvable dependency → dynamic tier (or conservative-widened height with the conditional input recorded as a latent edge so dirty-marking reaches it). A3 no mid-propagation graph mutation except speculative `rollback`, sequenced at propagation depth 0.

## Cut: deferred-writes and cross-propagation quiescence

The prior draft carried a deferred-write mechanism (effect side-writes spawn a fresh propagation) and a cross-propagation-quiescence theorem with a weaker "final firing" guarantee. **The spike showed it's unnecessary.** The uniform worklist (every write enqueues into the current drain) handles forward chains, contractive self-feedback, and backward writes correctly, with exactly-once for acyclic graphs — a *stronger* result than quiescence offered. `Computation.kind` (ckComputed/ckEffect), added for the deferred distinction, is currently unused by the scheduler and may be dropped unless a later direction needs it. *Evidence: test_effect_feedback + test_depth_and_backfeedback, all green under the uniform model.*

## Concurrent async sources and convergence

Glitch-freedom is intra-propagation. For multiple async sources writing during overlapping propagations: **serialization** by default (propagations atomic w.r.t. one another; a coarse propagation-identity token in CLS, set once at drain entry, never read by the hot `trackRead` path). **Opt-in order-independent convergence**, two tiers with the corrected algebra: `CommutativeMonoid` (assoc + comm ⟹ order-independence; idempotence *not* required — e.g. counters) and `Joinable` semilattice (+ idempotence ⟹ duplicate-robust, CRDT-shaped), recognized structurally at compile time. `Joinable` without serialization requires idempotence-tolerant downstream effects.

## Developer experience — a substrate contract

DX is defined by the substrate; only *rendering* is a frontend concern. A central `intonaco/verification` module owns the diagnostic contract:

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

Internal vocabulary (`height`, `SCC`, the static/dynamic tier) **never** surfaces to developers — they see consequences ("could read a half-updated value", "this value depends on itself"), not proof internals. `validate(Diagnostic)` rejects internal tokens outside an explicit expert channel. Diagnoses are tiered by *developer consequence* (error = your program is wrong; note = I added a runtime check, here's the cost; silent = you did nothing wrong), grouped root-cause-first across signals (a structural error pauses downstream checks rather than emitting a cascade). `-d:intonacoStrict` gates "zero runtime fallbacks" in CI. Any *rendering* of these diagnostics (a terminal devtools panel, a web overlay, a sinopia trace view) is a frontend's job, not the substrate's.

## Nim leverage — the standard

The substrate uses Nim's hard-but-powerful features rather than retreating to easier ones, because abstracting that difficulty *away from the end user* is the point of the library:

- **Typed macros** for compile-time height resolution.
- **The effect system** (`SignalRead`/`SignalWrite` tags + `std/effecttraits` + `{.effectsOf.}`) for sound, transitive, HOF-aware purity analysis — *not* hand-rolled AST descent. FFI is **forced-annotated** (not assumed-conservative — `getTagsList` is blind to C bodies), and `{.forbids.}` turns the tags into reactive-purity levers.
- **Custom-pragma value round-trip across modules** for the height carrier (with the `getImpl`+`eqIdent` workaround for the `getCustomPragmaVal` `typed`-param bug).
- **Compile-time VM** for iterative Tarjan/longest-path (iterative to respect VM recursion limits).
- **ORC** deterministic destructors + `{.nocursor.}` pins for the scheduler's hot path.
- **`{.push checks:off.}`** on the proven-safe drain loop.

"This Nim feature is hard / experimental" is not a valid reason to avoid the *correct* tool; "do the work to get it right" is the standard.

## Open questions

1. ~~**Effect-tag visibility.**~~ **RESOLVED (#49, committed `1fb0da0`):** `SignalRead`/`SignalWrite` ship as **first-class, exported** effects. Zero breakage across the 569-test corpus made exposure free (the feared `{.tags:[].}` conflicts didn't materialize — almost no code annotates explicit tags), and `forbids`-precision means the levers don't false-positive on `RootEffect`-laden code. The "strip from inference" option was moot — `effecttraits` can't work on an effect that isn't really inferred. See "Effect tagging resolved."
2. **Fragment size for future deep apps** is unmeasurable in advance — but Architecture B + the forcing function make it *large by construction*: the API steers toward statically-resolvable patterns and makes deviations loud. The number isn't predicted; it's enforced.
3. `CommutativeMonoid` vs `Joinable` — ship both.

## fresco conformance (downstream, not a constraint)

fresco's binding layer (`bindRow`/`bindCollection`/`region`) gets rewritten to emit the compile-time-scheduled form and builds under `-d:intonacoStrict`. The corpus is already mostly static-shaped (direct + builtin-formatted reads classify static even without descent); the work is rewriting the binding layer plus restructuring a handful of custom-formatter sites. This is downstream conformance — its scope is **never** a reason to soften a substrate decision (see the substrate-leads principle). The only fresco-derived objection that counts is "no real consumer could express this," never "fresco would need rework."

## Phasing

**DONE** (committed in intonaco):
0. Standalone test harness — `milpa.kdl` + `nimble test` (`6b7d9d8`, intonaco#47).
1. **Worklist scheduler** (the sound floor) + the ≤1-observer fast path (`989a7e4`, intonaco#48).
2. **Effect-tagged signal reads/writes** + `forbids` levers + the forced-FFI rule (`1fb0da0`, intonaco#49).
3. **Reactive-purity oracle + effect firewall** — `reactiveEffects`/`opaqueReactiveCalls` in `purity.nim` (`4f0380a`, intonaco#50). Reusable by #52/#4/#46.
4. **Compile-time height carrier** — `heightOf`/`composeHeight`/`withHeight` in `height.nim` (`007eea5`, intonaco#51). The `{.height: N.}` pragma read via getImpl+eqIdent (cross-module; `getCustomPragmaVal` fails across the typed-param boundary). `heightOf` is **partial** (`none` = not in the static fragment) so `composeHeight` propagates `none` on any unresolvable dep — making the static fragment **downward-closed**, which is what secures Lemma B at the static/dynamic seam.
5. **The hybrid classifier** — `classify(body): Classification{tier; height|reason}` in `classify.nim` (`e1cbf49`, intonaco#52). Composes #50 (opacity gate) + #51 (height resolution) + **callee-based** read detection (`()`/`get`, not arg-type — `fmtSig(a)` is AST-identical to `a()` otherwise). **v1 = bail-first**; the larger static fragment via descend-and-collect is the measurement-gated enhancement intonaco#57. Soundness pinned negatively: runtime-keyed / hidden / opaque / FFI / unbaked / mixed reads **never** classify static.

6. **Architecture B wiring** — `construct.nim` (`9536c4b`, intonaco#53): `computed`/`effect`/`dynamic` binding-owning macros + `archBAction` pure policy. STATIC bakes `{.height:h.}` onto the binding AND passes it as the runtime `fixedHeight`; `Computation.heightFixed` suppresses subscribe-time accumulation so the **baked height drives the scheduler** (the cross-check's teeth: a conditional node bakes the over-approx across both arms — height 3 — where accumulation sees only the taken branch (2) and would glitch). DYNAMIC → runtime floor + a consequence-tier warning (`-d:intonacoStrict` → hard error; `dynamic:` escapes it). `signals:` bakes source heights (0).

7. **`intonaco/verification` Diagnostic contract** — `verification.nim` (`7e0f47a`, intonaco#55): `Diagnostic`/`Severity`/`GlossaryTerm` (the union across all 5 directions) + `validate` (word-boundary internal-token rejection, expert bypass) + `group`/`surfaced` (an `sevError` root pauses its downstream cascade) + `render` (substrate-baseline message; panels are frontend). Added `subject: SignalId` over the sketch — grouping needs signal identity. Proven to fit AND catch the consistency checker's `height`-leaking reason (adoption: intonaco#59; transitive grouping: intonaco#58). This is the shared contract checkers 2–5 implement.

8. **Convergence concepts** — `convergence.nim` (`888cbb2`, intonaco#54): `CommutativeMonoid` (merge+unit) / `Joinable` (merge-only) concepts + `converge` (order-independent fold) + `holds{Commutative,Associative,Idempotent}` law witness-checks (**exhaustive = a proof on finite types** via `allValues`, sampled otherwise). Honest split: concepts recognize *shape*; laws are *witness-checked*, never claimed structurally proven. The propagation-identity token + serialize-vs-merge scheduler integration is the scheduler half, deferred to intonaco#60 (needs a concurrent-async-source consumer).

**NEXT:**
9. **fresco conformance** under strict; **mechanized proof** (Lean/Rocq: Lemma 2 observational glitch-freedom + Lemma B cross-tier monotonicity) for the research artifact (intonaco#56).

## Provenance

5 rounds of PhD-tier review (CS theory / DX / reactive-engine) followed by a build spike that turned the hypotheses into facts and *subtracted* a chapter (deferred-writes). Key reversals on the record: the round-3 cut of compile-time scheduling was an over-correction (it killed the differentiator) and was restored round 5 with the sound compositional carrier; the deferred-write theory survived five analysis rounds and died on first contact with a test. The lesson the spike encodes: analysis proposes, the compiler disposes.
