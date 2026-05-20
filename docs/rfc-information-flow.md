# RFC: Static information-flow analysis through the reactive graph

**Status**: Draft (headline research RFC)
**Author**: Corey Leavitt
**Companion to**: `docs/roadmap-compile-time-research.md`, `docs/rfc-intonaco-fresco-split.md`

## Summary

Layer an information-flow type system onto intonaco's static dependency graph (from `tracked:`). Signals carry trust labels (`Trusted[T]`, `Untrusted[T]`, custom domain labels). The reactive graph IS the dataflow graph; static analysis verifies that data with one label cannot reach a sink requiring a different label without passing through an authorized declassification step. Compile-time enforcement, zero runtime cost, generalizes to PII tracking, secret-token tracking, prompt-injection prevention, and beyond.

## Premise

Information-flow control (IFC) is a well-studied area of programming language research. The classical results — Denning's lattice model, the JFlow / FlowCaml languages, Jif, Paragon — show that static analysis can verify *who's allowed to learn what* through a program's data flow.

The classical problem is that IFC requires dataflow annotations. Real-world programs are not annotated with their dataflow graph; manually annotating every value's flow through every transformation is impractical. IFC has therefore stayed largely academic — production systems use runtime taint tracking instead, which is weaker, slower, and prone to false negatives.

**intonaco changes the cost equation.** The `tracked:` macro extracts the reactive dependency graph at compile time. Every signal's consumers are known. Every computation's signal reads are known. The dataflow graph is *automatic* — it's the byproduct of the reactive substrate. Layering an information-flow type system on top of an already-extracted dataflow graph is dramatically cheaper than building one from scratch on annotated imperative code.

The thesis of this RFC: **reactive runtimes with static dependency extraction are the natural substrate for practical information-flow control.** intonaco specifically is positioned to ship this work because the static-extraction machinery already exists.

## Why this matters now

Three concrete consumer scenarios drive the urgency:

1. **AI agent tool-call inputs.** An agent receives user input; the input gets parsed into tool-call arguments; the tool-call is dispatched. Today: any input can reach any tool argument. Prompt-injection attacks exploit this — user input that *looks like* tool-call instructions reaches the tool dispatcher. With information-flow: user input is `Untrusted[string]`; tool dispatchers require `Trusted[string]`; the unsafe path is a compile error.

2. **PII propagation.** A reactive UI displays user data; some derivations of that data may be shown to other users (e.g., audit logs); some derivations must never be. Today: PII tracking is by code review. With information-flow: PII-tagged signals can only reach sinks marked `pii-allowed`; leaks are compile errors.

3. **Secret tokens.** API keys, deploy tokens, session credentials. They flow through reactive state alongside everything else; today there's no static way to ensure they don't reach a logging sink, a display widget, or a serialization point. With information-flow: secrets are `Secret[T]`; only the API call sink accepts `Secret[T]`; a logger that takes `string` cannot receive a secret without explicit declassification.

All three are real production-shape problems. All three are statically verifiable given the reactive graph. None is solved by any current reactive library.

## Non-goals

- **Not a general-purpose IFC library.** The substrate is intonaco-specific. We're solving information-flow for *reactive* programs, where the dataflow graph is automatic. Imperative code outside intonaco's substrate gets no analysis.
- **Not a security panacea.** Static IFC catches *direct* flows. Indirect flows (timing channels, error-path leaks, control-flow-based information leakage) are out of scope for this RFC. They're addressable in follow-up work.
- **Not a substitute for runtime checks at trust boundaries.** Where intonaco meets the outside world (file IO, network reads, user input), the *labeling* happens at the boundary. The IFC system reasons about flow *given* the labels; it doesn't decide where labels come from.

## The type system

### Multi-axis trust labels

Real security labels are multi-dimensional. A value isn't just "trusted" or "untrusted" — it has a *confidentiality* level (who's allowed to read it?) and an *integrity* level (how trustworthy is the data?). These are orthogonal axes that compose; a value can be `Tainted` (low integrity, came from untrusted source) but `Public` (low confidentiality, can be shown to anyone), and the analysis treats those axes independently.

The default lattice ships two axes:

**Integrity axis** (how trustworthy is this value?):
```
Validated  ─ user input passed authorized validation; safe to act on
    ▲
    │
Tainted    ─ value came from untrusted source; not yet validated
```

**Confidentiality axis** (who can read this value?):
```
Secret       ─ API keys, session tokens, credentials
    ▲
    │
Confidential ─ user PII, internal business data
    ▲
    │
Internal     ─ within-org information
    ▲
    │
Public       ─ display-safe, no restrictions
```

A label is a *point* in the product space: `(IntegrityLevel, ConfidentialityLevel)`. The product of the two axes is itself a lattice with join (∨) and meet (∧) operations applied component-wise.

```nim
type
  IntegrityLevel* = enum  ilTainted, ilValidated
  ConfidentialityLevel* = enum  clPublic, clInternal, clConfidential, clSecret

  Label*[I: static[IntegrityLevel], C: static[ConfidentialityLevel], T] = distinct T

  # Convenience aliases for the common cases
  Tainted*[T]    = Label[ilTainted,   clPublic, T]
  Validated*[T]  = Label[ilValidated, clPublic, T]
  Secret*[T]     = Label[ilValidated, clSecret, T]
  PII*[T]        = Label[ilValidated, clConfidential, T]
  TaintedPII*[T] = Label[ilTainted,   clConfidential, T]
```

`Tainted[T]` and `Validated[T]` are the equivalents of what an earlier draft called `Untrusted[T]` and `Trusted[T]` — but using the correct axis name (integrity, not generic trust). `Secret[T]` is `Validated[T]` plus high confidentiality. `PII[T]` is `Validated[T]` plus confidential confidentiality. `TaintedPII[T]` is the combo (input that's both untrusted *and* confidential — e.g., a user submitting their own email address; not yet validated, and disclosure-controlled).

### User-extensible lattices

Consumers can declare additional axes via the `labelLattice:` macro:

```nim
labelLattice MedicalRecord:
  axis HIPAARegulation:
    HIPAAPublic ≤ HIPAARestricted ≤ PHI
  axis ConsentScope:
    NoConsent ≤ ResearchOnly ≤ FullConsent
```

This declares a custom lattice with two domain-specific axes. Values labeled `MedicalRecord[PHI, ResearchOnly, T]` carry HIPAA + consent semantics statically, with declassifiers required to move along either axis.

### Authorized transformations

Declassification — moving up *any* axis of the lattice — requires an authorized transformation. The cap concept system gates these:

```nim
# Integrity declassification: input validation
proc validate*[T](v: Tainted[T]): Validated[T] {.needs: ValidatorCap.} =
  ## Promote integrity. Caller must hold ValidatorCap (granted to the
  ## input-validation subtree by the supervisor).
  Validated[T](T(v))

# Confidentiality declassification: secret unmasking
proc unmask*[T](s: Secret[T]): Validated[T] {.needs: SecretAccessCap.} =
  ## Lower confidentiality from Secret to Public, keeping integrity at
  ## Validated. Caller must hold SecretAccessCap.
  Validated[T](T(s))

# Combined declassification for the PII display case
proc anonymize*[T](p: PII[T]): Validated[T] {.needs: PIIDisclosureCap.} =
  Validated[T](T(p))
```

A program that wants to display user input *must* go through `sanitize`:

```nim
let safe = sanitize(userInput())   # compile error if no SanitizerCap
displayLabel.set(safe)              # OK
```

Skipping the declassification is a compile error: `displayLabel.set(userInput())` fails because the types don't match.

### Implicit downgrading

Some transformations are *upward-safe* and don't require declassification: anything that produces a label at-or-below the consumed label is automatic.

```nim
proc echo*[T](s: Trusted[T]): Untrusted[T] = Untrusted[T](T(s))
  ## Trusted data echoed to an untrusted sink is automatically downgraded.
  ## No cap needed; this is a downward (safer) transformation.
```

The macro analysis recognizes the lattice direction and inserts implicit downgrades where the inferred direction is downward. Upward transformations always require explicit declassification.

### Type-level flow through the reactive graph

When a computation depends on a signal, the label of the signal flows into the computation's output:

```nim
let upper = computed(): string =
  userInput().toUpperAscii()
# inferred type: Signal[Tainted[string]]
# (computation reads Tainted, returns the same label)
```

If a computation reads from multiple labeled signals, the output's label is the *join* (least upper bound) of all inputs along *every* axis:

```nim
let combined = computed(): string =
  userInput() & " — " & userEmail()
# userInput: Tainted, Public
# userEmail: Validated, Confidential
# join: Tainted, Confidential
# inferred type: Signal[Label[ilTainted, clConfidential, string]]
```

The label inference happens at macro-expansion time over the `tracked:`-extracted dep graph. No runtime cost.

### Indirect flows: branches on labeled discriminators infect their bodies

A direct-flow analysis catches `outputSignal.set(taintedInput())`. But the realistic attack pattern in AI agent code (and elsewhere) is *indirect*:

```nim
let userMsg: Signal[Tainted[string]] = ...
let isAdmin = computed(): bool =
  # check whether user's message starts with the admin trigger phrase
  userMsg().startsWith("/admin ")

if isAdmin():                          # ← branch on Tainted discriminator
  outputSignal.set("admin command")    # ← writes Validated, but the
                                       #   decision-to-write came from Tainted
```

The output signal isn't *directly* assigned tainted data, but the *decision to write* depends on tainted input. This is the prompt-injection attack class.

The substrate handles this by **propagating labels through branches on labeled discriminators**:

- A `case discriminator: ...` or `if discriminator: ...` where `discriminator`'s type is `Label[I, C, _]` causes the bodies' outputs to inherit `(I, C)` on the join.
- Equivalently: every value written or computed inside the branch body has its label joined with the discriminator's label.

In the example above, `isAdmin()` is `bool` typed but its computed-output label is `Tainted, Public` (inherited from `userMsg`). The `if isAdmin():` body is then implicitly tainted. The `outputSignal.set("admin command")` would require declassification to write a `Validated`-labeled value from inside a `Tainted` branch — which is a compile error unless an explicit declassification appears.

This catches the indirect-flow attack at compile time with no consumer-side annotation.

The substrate does *not* attempt full control-flow analysis (timing channels, exception-path leakage, error-message side-channels). Those are out of scope; documented as such; addressable in follow-up work if a real consumer demands them.

## Cap-substrate integration

Information-flow ties into the existing cap concept system in two ways:

### 1. Declassification caps as authority tokens

`SanitizerCap`, `SecretAccessCap`, `PIIDisclosureCap` are intonaco-style caps declared via `cap`. Code that performs declassification requires the corresponding cap in its `{.needs.}` list. The supervisor wiring decides which code paths are authorized to declassify.

```nim
cap SanitizerCap
cap SecretAccessCap
cap PIIDisclosureCap

let sup = supervisor:
  # Production: declassification is allowed in the input-sanitizer subtree.
  child userInputHandler
  supervisor:
    provides(SanitizerCap)
    child sanitizingTransform
```

Only `sanitizingTransform` can call `sanitize(...)`. The rest of the program *can't* declassify; the type system enforces it.

### 2. Sink caps as flow targets

Sinks that consume labeled data declare their requirements:

```nim
proc renderToUI(label: Trusted[string]) {.needs: UIRenderCap.} = ...
proc writeToAuditLog(entry: PII[string]) {.needs: AuditLogCap.} = ...
proc sendToAPI(token: Secret[string]) {.needs: APIAccessCap.} = ...
```

The compile-time check is two-axis: the data's label must match the sink's requirement *and* the calling code must have the sink's authority cap.

## The reactive graph as the dataflow graph

The architectural payoff: intonaco's `tracked:` already extracts the dataflow. Every `Signal[Untrusted[T]]` has a known set of computations that depend on it. Every computation has a known set of source signals. The dataflow graph is the reactive graph.

Information-flow analysis becomes:
1. For each signal, look at its computed-graph closure (transitive consumers)
2. For each transitive consumer, check its output label is consistent with its input labels (per the lattice)
3. For each sink in the closure, check the sink's label requirement is satisfied
4. Surface any mismatches as compile-time errors

This is the classical IFC algorithm — but where prior work spent most of its effort *extracting* the dataflow graph from annotated code, we skip that step. The reactive substrate provides it.

The expected analysis cost is `O(graph size)` per compilation; modest constant factors. For realistic reactive programs (hundreds to thousands of signals), the analysis runs in macro-expansion time without significant compile-time impact.

## Engineering primitives that fall out

The user-facing API the engineering audience consumes:

### Trust label types

`Trusted[T]`, `Untrusted[T]`, `Secret[T]`, `PII[T]` as the standard set. Consumers declare custom labels per-domain:

```nim
cap PIIDisclosureCap

type
  HipaaProtected*[T] = distinct T
  GDPRPersonalData*[T] = distinct T

# Lattice definition macro:
labelLattice:
  HipaaProtected   -> Trusted via hipaaDisclose {.needs: HipaaCap.}
  GDPRPersonalData -> Trusted via gdprDisclose {.needs: GDPRCap.}
```

### `sanitize` / `unmask` / `disclose` declassifiers

Built-in declassifiers for the standard set, plus a macro to declare custom ones with cap requirements.

### Compile errors with named labels

When information flow analysis fails, the error message names the involved labels:

```
Error: information flow violation at `displayLabel.set(userInput())`
       userInput is Signal[Untrusted[string]]
       displayLabel.set expects Trusted[string]
       declassification path: sanitize(Untrusted[T]): Trusted[T]
                              {.needs: SanitizerCap.}
       — wrap with `sanitize(...)` and ensure SanitizerCap is granted by the supervisor.
```

The error is actionable, not generic.

### Static cycle detection as a side-effect

The analysis walks the reactive graph. Cycles (A depends on B, B depends on A) are naturally detected during the walk. We surface them as their own compile error:

```
Error: reactive cycle detected
       A depends on B (line 42)
       B depends on A (line 67)
       — break the cycle by introducing a `computed:` with explicit dep declaration.
```

This is the "static cycle detection" engineering primitive that the roadmap mentioned. It falls out for free.

### Dead-signal elimination as a side-effect

Signals with no transitive consumers in the closure are flagged as warnings:

```
Warning: signal `unusedCount` has no consumers
       declared at line 18, no transitive observers found.
       — remove or annotate as `{.exported.}` if intentional.
```

Another free engineering primitive.

### Sink-side inference helper

A macro that, given a sink proc, computes the minimum label its input must have:

```nim
proc renderToUI(label: Trusted[string]) {.needs: UIRenderCap.} = ...
# requireLabel(renderToUI) → Trusted

proc sendToAPI(token: Secret[string]) {.needs: APIAccessCap.} = ...
# requireLabel(sendToAPI) → Secret
```

Useful for tooling: a devtools view can show "which sinks accept which labels" at a glance.

## Research contribution

The paper-worthy claims:

1. **Reactive runtimes with static dependency extraction obviate the manual-annotation cost of classical IFC.** Prior IFC implementations spend most of their analysis effort building the dataflow graph; intonaco gets it for free.

2. **Capability-typed declassifiers provide a clean authorization model.** Rather than ambient declassification permissions (Jif's "actor" model), intonaco's cap concepts give precise compile-time authorization.

3. **The information-flow lattice composes with effect classification and substructural caps** (research directions 2 and 3 in the roadmap). A signal's full type is `(value type) × (trust label) × (effect set) × (cardinality)`. Each axis is independently verified.

Working title for the research artifact: *"Free information-flow control: reactive dependency graphs as static dataflow substrates."* Targets an FRP or PL venue (POPL workshops, FRP workshops, or potentially a paper at PLDI / OOPSLA depending on scope).

## Implementation phases

Each phase produces a shippable engineering increment.

### Phase 1: multi-axis lattice + label types

- `Label[I, C, T]` parameterized two-axis label type
- `Tainted` / `Validated` / `Secret` / `PII` / `TaintedPII` convenience aliases
- `labelLattice:` macro for declaring additional domain axes
- Compile-time lattice join/meet over both axes
- Tests: lattice ordering for built-in axes + a sample two-axis user lattice

**Acceptance**: a user can declare `Signal[Tainted[string]]`, the lattice is queryable at compile time, multi-axis user lattices work. No flow analysis yet.

### Phase 2: declassifier macros

- `declassifier T -> U via fn {.needs: Cap.}` macro for declaring authorized transformations
- Compile errors when declassifiers are called without the required cap
- Built-in declassifiers for the standard set
- Tests: cap-gated declassification

**Acceptance**: declassification works; cap-gating works; the type lattice is consistent.

### Phase 3: dataflow + branch-flow analysis over `tracked:` graph

- Macro analysis walks the reactive graph
- Label inference for `computed:` outputs based on input labels (join along every axis)
- **Branch-flow analysis**: `if` and `case` discriminators of labeled types infect their bodies' outputs with the discriminator's label
- Mismatch detection: signal write with wrong label is a compile error
- Tests: typed signals through computations to sinks, with and without declassification; indirect-flow attack patterns (regex-on-tainted-then-write-validated) caught as compile errors

**Acceptance**: a user writes a fresco app with typed signals; direct mismatches AND indirect-flow attacks are caught at compile time.

### Phase 4: sink integration with cap discharge

- Sinks declare their label + cap requirements via `{.needs.}`
- Compile-time check that flow paths are authorized end-to-end
- Tests: realistic scenarios (untrusted input → sanitizer → display; secret read → API call)

**Acceptance**: end-to-end information flow scenarios verified.

### Phase 5: side-product engineering primitives

- Static cycle detection
- Dead-signal warnings
- `requireLabel` introspection helper
- Devtools view showing label flow through the graph

**Acceptance**: the engineering primitives that fall out of the analysis are available as their own tools.

### Phase 6: research artifact

- Blog post articulating the contribution
- Example consumer demonstrating the analysis (probably a small AI agent example with sanitize + secret-handling)
- Workshop paper submission (if venue match)

**Acceptance**: the research contribution is articulated, citeable, and adopted by at least one example.

## Estimated effort

~6 months from first commit to Phase 6 complete. Roughly:

- Phase 1: 3 weeks (small substrate)
- Phase 2: 3 weeks (macros + tests)
- Phase 3: 8 weeks (the hard analytical work)
- Phase 4: 4 weeks (integration with caps)
- Phase 5: 4 weeks (side primitives, polish)
- Phase 6: 4 weeks (artifact writing)

LoC estimate: ~2000 lines of substrate + ~500 lines of tests + significant macro work + documentation.

## Open design questions

### Q1: Implicit declassification at trust boundaries

When a string is read from a file via `readFile(path)`, what's its label? `Tainted` is the safe default. But a config file the developer fully controls is intuitively `Validated`. How do we mark it?

Lean: input boundaries are declared via the cap system. A `{.needs: TrustedFsReadCap.}` cap means "this read site is authorized to mark the result `Validated`." Without that cap, file reads produce `Tainted`. The supervisor decides who gets `TrustedFsReadCap`.

This generalizes: every input boundary has a label-producing cap. The principle: the cap concept system decides *where labels come from*, not just where they go.

### Q2: Performance of macro analysis on large reactive graphs

The analysis is `O(graph size)`. For thousands of signals, this is fast. For tens of thousands, it might become noticeable in compile times. Pragmatic mitigations:

- Incremental analysis (cache results, re-analyze changed subgraphs only)
- Coarse-grained analysis with `{.opaque.}` boundaries (a subgraph marked opaque is analyzed once, treated as a black box thereafter)
- User-controllable analysis depth

Punted to implementation: build the naive version first, measure, optimize if needed.

### Q3: Reading inner values without declassification

Given `let u: Tainted[string] = userInput()`, is `T(u)` (unwrap to the raw inner) a privileged operation or a free one?

Two positions:

- **Free unwrap**: `T(u)` returns the inner value with no label. Useful for read-only inspection (e.g., `echo u` for debugging). Risk: the value can flow into untyped Nim code where the label is lost.
- **Privileged unwrap**: `T(u)` requires a cap, same as declassification. Stricter; matches Jif/Paragon semantics. Cost: huge friction for ordinary code that just wants to *look at* the value without flowing it.

Lean: **a middle path** — `inspect(u): T` (no-cap-required) returns the inner value but marks it `{.discardable.}` so the result can only be used in non-flow positions (echo, log, print). `unwrap(u): T {.needs: UnwrapCap.}` allows full unwrap for code that legitimately needs the raw value. Default unwrap (`T(u)`) is *disallowed* — must use one of the two named operations.

This is consistent with the rest of fresco: the cap system mediates access, and the user picks the appropriate operation per intent.

### Q4: Interaction with speculative scope

Speculative scope rolls back signal writes. If a `Secret` signal is written in speculative scope and the speculation is reverted, is the original value still considered to have leaked? Most IFC models would say yes (the write happened, the value was readable during the speculation). Pragmatic answer: speculative writes are full writes for IFC purposes; revert doesn't undo information disclosure.

This is consistent with intonaco's existing speculative semantics (optimistic-revert, not transactional isolation).

### Q5: Compatibility with the existing cap concept system

A signal's full type post-this-RFC: `Signal[Label[I, C, T]]`. A binding consuming the signal must `{.needs.}` any caps for the sink. The cap concept system already handles the cap discharge; this RFC adds the label-discharge on top. The two systems compose cleanly because both are concept-based.

Open question: does the compile-error message for a *combined* failure (wrong label AND missing cap) usefully name both, or does it surface only one?

Lean: name both. Macro logic checks label first, then cap; if both fail, emit both error lines.

## Connection to AI agent use cases

The motivating application family. intonaco-built AI agents benefit directly:

```nim
# Agent setup:
let userMessage = signal(Tainted[string](""))
let toolCallArgs = computed(): Tainted[ToolCall]:
  parseToolCall(userMessage())   # parser returns Tainted output
  # because input is Tainted

cap PromptValidatorCap
declassifier Tainted[ToolCall] -> Validated[ToolCall] via validateToolCall
  {.needs: PromptValidatorCap.}

proc dispatchTool(call: Validated[ToolCall]) {.needs: ToolDispatchCap.} = ...

# Wiring:
let sup = supervisor:
  provides(ToolDispatchCap)
  child mainAgentLoop
  supervisor:
    provides(PromptValidatorCap)
    # only this subtree can declassify tool calls
    child validator

# In mainAgentLoop:
let unsafe = toolCallArgs()
let safe = validateToolCall(unsafe)   # compile error if PromptValidatorCap not in scope
dispatchTool(safe)                     # OK

# Indirect-flow attack also blocked:
let isAdmin = computed(): bool =
  userMessage().startsWith("/admin ")    # inferred label: Tainted, Public
if isAdmin():
  # branch body inherits Tainted from discriminator
  adminPanel.set("granted")              # compile error: cannot write
                                         # Validated under Tainted control flow
                                         # without declassification
```

The result: an AI agent where tool dispatch is *type-checked* to receive only sanitized arguments. Prompt injection attacks become compile-time errors at the wiring layer.

This is genuinely novel. No current AI agent framework provides this guarantee.

## Why this is the headline research RFC

Three reasons it earns priority over the other five research directions:

1. **Highest leverage per LoC.** Information-flow is the substrate that effects, linear caps, temporal invariants, and UI completeness all benefit from. The label-flow infrastructure is reused by every subsequent direction.

2. **Highest concrete consumer value.** AI agent safety, PII compliance, secret-handling — all are real problems for real consumers (current and prospective). The other directions are valuable but more diffuse in their consumer appeal.

3. **Most novel architectural claim.** "Reactive runtimes obviate the IFC annotation cost" is a paper-worthy thesis on its own. The other research directions are extensions of existing techniques to a new substrate; information-flow is a new substrate enabling a previously-impractical technique.

Together: it's the right first major compile-time-research direction for intonaco to ship.

## Decision log

(Empty initially. Decisions made during implementation get appended.)
