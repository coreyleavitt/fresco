# RFC: sinopia — trace frontend on intonaco

**Status**: Draft
**Author**: Corey Leavitt
**Companion to**: `docs/rfc-intonaco-fresco-split.md`, `docs/rfc-reactive-observability.md`
**Depends on**: intonaco substrate (Phase 3 of the split RFC)

## Why this RFC exists

The intonaco / fresco split RFC declares intonaco a frontend-agnostic reactive substrate and fresco its terminal frontend. The substrate's portability claim — "intonaco bakes in no rendering opinions; future frontends target the same primitives" — is currently *asserted*, not *demonstrated*. The only frontend that exists is fresco. The only render model that exists is a row-based 2D terminal grid. The "headless" path inside fresco is just fresco's row-based renderer with output rerouted to memory; it does not exercise a different render model, it exercises a different sink for the same model.

A claim of substrate-portability that is never tested against a second frontend is not architecturally meaningful. Six months from now we discover the substrate has subtly assumed `setRow(int, string)` somewhere in its bones, and the abstraction was always a fiction.

This RFC proposes **sinopia**: a sibling frontend to fresco, depending on the same intonaco substrate, with a deliberately and radically different render model. Sinopia's render target is a *trace* — a time-series of structured causal events emitted as reactive state changes — not a spatial surface. If intonaco supports sinopia cleanly, the portability claim is real. If it does not, sinopia tells us where the substrate leaked terminal assumptions.

Sinopia is, in equal parts:

1. **A substrate validator.** A second frontend with a render model so different from fresco that any terminal-shaped assumption in intonaco surfaces immediately.
2. **An observability tool.** A trace-based assertion / inspection layer for fresco apps. Bind a sinopia trace to the same signals fresco's bindings render — get structured time-series observability for free, queryable with the same predicate DSL as the devtools panel.
3. **A pattern exemplar.** If anyone later builds fresco-web or any other frontend, sinopia is the worked example of how to target intonaco without inheriting fresco's terminal shape.

## The name

In Renaissance fresco-making there are four layered surfaces, applied in order:

1. **arriccio** — the rough underlying plaster
2. **intonaco** — the smooth top plaster onto which paint is applied
3. **sinopia** — a red-pigment preparatory *underdrawing* sketched on the intonaco before paint goes on; the structural plan beneath the finished work
4. **fresco** — the finished painting

The intonaco/fresco split RFC chose the first two names by their physical relationship: paint (fresco) sits on plaster (intonaco). The sinopia is the third layer in that sequence — the structural sketch *visible only when you strip the paint*. Metaphorically: sinopia (the trace tool) lets you see the structural reactive activity *underneath* the visible fresco UI.

The three names map exactly to three real fresco-making layers, all Italian, all Renaissance, all single words. The metaphor is literal, not strained. The unique-in-software-search property of intonaco extends to sinopia.

## The render model

The crucial distinction:

- **fresco's render target is spatial.** A 2D grid of rows × columns. Bindings emit content *at positions*: `bindRow region, idx: expr`. The render model has a "where."
- **sinopia's render target is temporal.** A causal-chronological log. Bindings emit structured events *in causal order*: `traceSignal sig, label = "..."`. There is no "where" — only "when," "what changed," and "what caused it."

These are not minor stylistic differences; they are different abstract shapes. fresco's binding signature is `(target, position, expr) -> render side-effect`. sinopia's is `(signal, label) -> trace entry`. There is no row index. There is no width. There is no scrolling. The render model has no notion of layout at all.

This is exactly the point. By choosing a render model that shares no spatial primitives with fresco, sinopia forces intonaco's substrate API to expose only frontend-agnostic operations: subscribe to a signal, observe its changes, run inside a scope, discharge a capability. If any of these implicitly require a row or region, sinopia cannot be built. If sinopia can be built, the substrate API is genuinely portable.

## The user-facing shape

A sinopia app looks structurally like a fresco app, but with `traceX` bindings replacing `bindRow` / `bindCollection` and no Screen / Region / Layout types in scope:

```nim
import intonaco
import sinopia

proc agentBehavior(stream: SinopiaInputStream) {.async.} =
  signals:
    count = 0
    status = "ready"

  # Bindings — trace targets, not render targets:
  traceSignal count, label = "user.count"
  traceSignal status, label = "user.status"
  traceTransition status: "ready" -> "working" emit "user.startWork"
  traceTransition status: "working" -> "ready" emit "user.finishWork"

  while true:
    let event = await stream.nextEvent()
    case event.kind:
      of seIncrement: count.set(count() + 1)
      of seStart:     status.set("working")
      of seFinish:    status.set("ready")
      of seQuit:      return

# Running it produces a Trace:
let trace = await runTrace(agentBehavior, inputs = @[
  evIncrement, evIncrement, evIncrement,
  evStart, evFinish,
  evQuit,
])

# The trace is queryable:
for entry in trace.events:
  echo entry.timestamp, " ", entry.label, " = ", entry.value, " (cause: ", entry.causedBy, ")"

# Test assertions against the trace:
check trace.eventsOf("user.count").last.value == "3"
check trace.transitionsOf("user.status") == @["ready->working", "working->ready"]
check trace.firstEventAfter("user.startWork", "user.finishWork").existsWithin(5.seconds)
```

The output looks like:

```
[t=0]    signal "user.count" = 0           (cause: bind)
[t=0]    signal "user.status" = "ready"    (cause: bind)
[t=12]   signal "user.count" = 1           (cause: input seIncrement)
[t=18]   signal "user.count" = 2           (cause: input seIncrement)
[t=24]   signal "user.count" = 3           (cause: input seIncrement)
[t=30]   signal "user.status" = "working"  (cause: input seStart)
[t=30]   transition "user.startWork"        (cause: input seStart)
[t=42]   signal "user.status" = "ready"    (cause: input seFinish)
[t=42]   transition "user.finishWork"       (cause: input seFinish)
[t=48]   scope closed                       (cause: input seQuit)
```

## What sinopia ships

### Trace bindings

Frontend-specific glue layered on intonaco's `createEffect`. Each binding subscribes to a substrate primitive and emits structured trace entries when it changes.

- `traceSignal sig, label = "..."` — subscribe to sig's writes; emit a trace entry per write, carrying value, timestamp, and the causing event (input, scope-open, parent signal write).
- `traceTransition sig: oldVal -> newVal emit "name"` — emit only when sig moves between specified values. The trace entry is named, not value-labeled. Useful for state-machine observability.
- `traceCollection coll, label = "..."` — for `CollectionSignal[T]`, emit one trace entry per delta (insert/remove/update). The entry carries the delta itself, not the full collection.
- `traceScope scope, label = "..."` — emit on scope open and scope close. Used to mark phase boundaries in the trace.
- `traceEffect eff, label = "..."` — emit when an effect re-runs. Used to observe reactive recomputation.
- `traceCap cap, label = "..."` — emit when a capability is discharged at a wiring site. Useful for security/audit traces (every privileged operation is logged).
- `traceJournal label = "..."` — emit every journal event globally. The trace becomes a structured mirror of the journal log, with sinopia's labeling layered on top.

Each binding is built on `createEffect` (intonaco's substrate primitive) plus sinopia's `currentTrace()` accessor. No new substrate primitive is required for any of them. *That is the substrate-validation evidence.*

### The Trace capture type

```nim
type
  TraceEntry* = object
    timestamp*: Moment              # chronos Moment
    label*: string                  # user-supplied or binding-derived
    kind*: TraceKind                # signal write, transition, scope event, ...
    value*: JsonNode                # serialized payload
    causedBy*: Option[JournalId]    # causal-chain backref into the substrate journal
    scopePath*: seq[string]         # scope hierarchy at entry-time

  Trace* = ref object
    events*: seq[TraceEntry]
    startedAt*: Moment
    endedAt*: Moment
    inputs*: seq[SinopiaEvent]      # the inputs that drove this trace
```

Trace entries carry `causedBy` to integrate with intonaco's causal-chain machinery. A sinopia trace is queryable both standalone (sinopia's own query helpers) and via the journal's causal-ancestor walk (cross-referenced with `parentEvt` chains).

### Query and assertion helpers

A subset of the predicate DSL from the devtools-experience RFC, adapted to operate over a Trace:

```nim
trace.eventsOf("user.count")              # filter by label
trace.transitionsOf("user.status")        # filter to transition entries
trace.eventsBetween(t0, t1)               # time-range filter
trace.eventsAfter("user.startWork")       # causal-after filter (using causedBy)
trace.firstEventOf(label)
trace.lastEventOf(label)
trace.causalChainTo(entry)                # walk causedBy back to root
```

These are not the full devtools predicate-DSL — they are sinopia's read-side surface. The full DSL is a substrate primitive (from the observability RFC) and lives in intonaco; sinopia's helpers consume it.

### SinopiaInputStream

Synthetic input source analogous to fresco's `SyntheticInputStream`, but events are *not* KeyEvents. A sinopia app's "input" is whatever the app decides — domain events, MCP tool calls, message arrivals, ticking clocks. The stream interface:

```nim
type
  SinopiaInputStream*[T] = ref object
    queue: AsyncQueue[T]

proc nextEvent*[T](s: SinopiaInputStream[T]): Future[T] {.async.}
proc push*[T](s: SinopiaInputStream[T], event: T)
proc close*[T](s: SinopiaInputStream[T])
```

Generic over event type. A sinopia app declares its event type at app-definition time. Driving the app from a test is just `stream.push(event)`. The substrate cancel-safety guarantees from intonaco apply here too.

### The runTrace harness

```nim
proc runTrace*[T](
  app: proc(stream: SinopiaInputStream[T]): Future[void] {.async.},
  inputs: seq[T] = @[],
  timeout = 5.seconds,
): Future[Trace] {.async.}
```

Spawns the app under a fresh `Trace` capture, feeds it the inputs sequentially, runs until the app returns or the timeout elapses, and returns the captured trace. Pure substrate primitives — no terminal, no Screen, no fd. The harness is structurally analogous to fresco's `runHeadless` but renders into a Trace instead of a MemorySink.

## Why sinopia validates intonaco's portability claim

The fresco-internal `runHeadless` + `MemorySink` path validates a strictly weaker claim: *fresco's row-based render model supports more than one sink.* That tests fresco's sink abstraction, not intonaco's substrate.

Sinopia's render model shares *nothing* with fresco's:
- No row. No column. No width. No height. No region. No layout. No setRow. No diff. No paint.
- No terminal. No fd. No ANSI. No alt-screen.
- No spatial primitive of any kind.

For sinopia to build on top of intonaco, the substrate must expose:
- Signal subscription that doesn't require a render target.
- Scope lifecycle hooks that don't require a region.
- Capability discharge that doesn't require terminal capabilities.
- Effect re-run notifications that don't bake in any output shape.
- Journal events that are content-agnostic.

These are the actual primitives intonaco *needs* to be portable. If any of them quietly requires a Region or row index, sinopia fails to build. The compiler tells us where the leak is.

This is the same logic that makes Rust's borrow checker valuable — you can't *claim* memory-safety; you have to *demonstrate* it by passing the checker. Sinopia is the substrate's borrow-checker analog: a second frontend so different that the substrate can't fake portability against it.

## Co-running with fresco

A single app can plausibly bind both fresco *render* bindings and sinopia *trace* bindings on the same signals:

```nim
proc app(...) {.async.} =
  signals:
    count = 0

  # Visible UI:
  bindRow region, 0: "Count: " & $count()

  # Structured observability:
  traceSignal count, label = "ui.count"
```

This is supported by construction — `bindRow` and `traceSignal` are both built on `createEffect`, and intonaco's substrate makes no assumption that a signal has at most one binding. Co-running gives developers inline observability: the UI runs normally; the trace captures structured evidence of what happened.

This pattern enables a workflow we've discussed in the devtools-experience RFC: *capture a trace of an interactive session, ship it to a developer as a bug report, replay-assert against it.* fresco renders the UI; sinopia captures the trace; the trace is the structured artifact. Both are running simultaneously over the same substrate.

## Repository layout

```
coreyleavitt/sinopia
├── sinopia.nimble                        # requires "intonaco"
├── README.md
├── LICENSE                               # Apache 2.0
├── src/sinopia.nim                       # top-level re-exports
└── src/sinopia/
    ├── trace.nim                         # Trace, TraceEntry types + query helpers
    ├── bindings.nim                      # traceSignal, traceTransition, traceCollection, ...
    ├── input.nim                         # SinopiaInputStream[T]
    └── runner.nim                        # runTrace harness
└── tests/
    └── ...                               # mostly substrate-validation tests
```

Initial repository: private, similar to intonaco's current state. README points at this RFC. LICENSE is Apache 2.0 (matching fresco/intonaco). The package depends on `intonaco` and only `intonaco` — no fresco, no terminal anything, no chronos input adapters that assume fd input.

## Phasing

Sinopia depends on intonaco being its own package (Phase 3 of the split RFC). Until intonaco exists, sinopia cannot be cleanly authored against the substrate (it would have to import fresco-the-monolith and accidentally pull in terminal code). Therefore sinopia phasing is *gated on* the split RFC's Phase 3.

### Phase 0: This RFC + private repo placeholder (now)

- Land this RFC in `docs/rfc-sinopia.md` (fresco repo, for visibility while intonaco doesn't yet exist as its own repo).
- Create `coreyleavitt/sinopia` private repo with placeholder README pointing at this RFC and Apache 2.0 LICENSE.
- Update fresco's CLAUDE.md / DESIGN.md / README to declare the three-package architecture and reference sinopia as the planned third sibling.
- No code written yet.

### Phase 1: Trace + bindings + runner (after intonaco Phase 3)

- `trace.nim` — Trace, TraceEntry, query helpers
- `bindings.nim` — `traceSignal`, `traceTransition` (other bindings deferred to Phase 2)
- `input.nim` — `SinopiaInputStream[T]`
- `runner.nim` — `runTrace`
- Substrate-validation tests: every binding is tested by running an app against `runTrace` and asserting on the captured Trace.

**Acceptance:**
- A sinopia app builds without importing anything from fresco.
- `runTrace` returns a meaningful Trace.
- At least one substrate-leak issue surfaces during this phase (or, if not, that's evidence the substrate is genuinely clean — record this in the decision log).
- The repo flips to public.

### Phase 2: Full binding surface

- `traceCollection`, `traceScope`, `traceEffect`, `traceCap`, `traceJournal`
- Causal-chain integration (`causedBy` populated from intonaco's journal events)
- Query DSL fleshed out

### Phase 3: Co-running validation

- Build a non-trivial example app that runs both fresco and sinopia bindings on the same signals.
- Validate the trace produced by the co-running app matches expectations on visible UI behavior.
- Document the pattern in `examples/`.

### Phase 4: Trace serialization

- JSONL persistence format for traces.
- A `replayTrace(path)` function that rebuilds a Trace from disk (useful for shipping traces as bug reports).
- Cross-reference with the journal persistence format from the observability RFC — likely overlapping primitives.

## Open design questions

### Q1: Should the trace be bounded?

Long-running apps emit unbounded traces. For pure observability we want the full history; for testing we want it bounded by the test's input length. Options:

- **Unbounded by default.** Trust the caller to scope `runTrace` durations. For production observability, layer a separate ring-buffer mode.
- **Bounded by default (e.g., 10k entries), with a `bounded = false` opt-out.** Safer default, but cuts traces silently if the user forgets.
- **Mode-selected at runTrace call.** `runTrace(app, inputs, mode = tmFull)` vs `tmRing(capacity = 10_000)`.

Lean: mode-selected at runTrace. Explicit, no silent loss, the common cases stay short.

### Q2: Causal-chain backrefs into the substrate journal

Each TraceEntry has `causedBy: Option[JournalId]`. This depends on intonaco's journal already producing IDs that survive across substrate boundaries (the observability RFC discusses this; the IDs are currently in-memory only). If the substrate's IDs are stable enough to backref into, the sinopia trace and the intonaco journal become *the same causal graph viewed two ways*. If they aren't, sinopia gets its own ID scheme and the causal cross-link is sinopia-internal.

Lean: depend on the observability RFC's persistent IDs. Don't ship sinopia until the journal has stable IDs.

### Q3: Capability tracing

`traceCap cap, label = "..."` is potentially powerful for security audit — every privileged operation gets a labeled trace entry, the trace becomes a queryable security log. Open question: is it always-on (any cap discharge automatically appears in the trace if any traceCap is bound), or strictly explicit (only the caps the user named appear)?

Lean: explicit. Surprising-by-default is bad. Users opt into the caps they care about. A future `traceAllCaps()` global can flip it for security audit modes.

### Q4: Sinopia for non-fresco apps

Sinopia depends only on intonaco. A pure-substrate program — a daemon, a worker, an agent with no UI — can use sinopia for observability without ever touching fresco. This is a valid and important use case: agentic workflows, MCP servers, supervised job runners, anything intonaco-shaped that wants structured causal observability.

Open question: do we ship a separate sinopia example demonstrating this (a no-UI worker traced with sinopia)? Lean: yes, Phase 3 includes a fresco-less example. The pattern needs documentation; the substrate-only path is one of the main motivations.

### Q5: Trace as journal vs. trace alongside journal

intonaco's journal already records substrate events. A sinopia trace is at first glance "the journal with labels." Two interpretations:

- **Sinopia trace replaces the journal for user-facing observability.** Users bind `traceX` bindings and never look at the raw journal; the trace is the *named, queryable* view of substrate activity.
- **Sinopia trace is layered on top of the journal.** The journal is still substrate-internal; the trace is a frontend-specific filtering/labeling of it.

Lean: layered on top. The journal stays the source of truth (it's where the substrate writes); the trace is the frontend's labeled, queryable view. Two reasons: (a) the journal is consumed by multiple frontends (devtools panel, sinopia, future frontends), so it shouldn't be sinopia-shaped; (b) the trace's labels are sinopia-specific naming, not substrate-canonical.

## Why now

Sinopia is being declared now, mid-pre-1.0, for the same reasons the intonaco/fresco split is being declared now:

1. **The substrate is currently being authored.** Every substrate primitive added without a non-fresco frontend in mind risks baking in terminal assumptions. Declaring sinopia now puts a hypothetical-but-real second consumer in scope while substrate decisions are made.
2. **No production users yet.** Substrate changes driven by sinopia have no migration cost on consumers.
3. **The portability claim needs evidence.** Declaring intonaco "frontend-agnostic" without a second frontend in the queue is unfalsifiable. Sinopia gives the claim something to fail against.
4. **Co-running observability is a real product feature.** A trace-on-top-of-UI workflow is something fresco apps want anyway; sinopia is the path that delivers it cleanly instead of bolting it onto fresco's renderer.

## Decision log

(Empty initially. Decisions made during implementation get appended.)
