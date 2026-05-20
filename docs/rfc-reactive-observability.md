# RFC: Reactive observability — observe, query, manipulate, replay

**Status**: Draft
**Author**: Corey Leavitt
**Supersedes**: #57 (v3: devtools binary / sidecar app shell)
**Companion to**: `docs/rfc-devtools-experience.md` — this RFC specifies the **substrate** (queries, predicates, subscriptions, journal access); the devtools-experience RFC specifies the **surface** (what users see, how they interact, the novel UX claims). Both reference each other.

## Why an RFC and not a /tdd cycle

The work originally filed as #57 was framed as a 2-bucket question — *embedded panel* vs *out-of-process sidecar*. Both buckets are conservative uses of fresco's substrate. Examined honestly, fresco has architectural properties that almost nothing else has (totally-ordered persistent journal + reactive-runtime-emits-everything + replay-already-in-substrate), and using them to power "a panel that shows you state" is leaving 80% of the value on the table. The right framing is a layered observability architecture in which the panel is one of several renderers over a richer substrate.

This RFC defines that architecture and phases its implementation. It supersedes #57 as the parent issue for the milestone.

## Non-goals

- **Not Chrome DevTools.** The point isn't to reimplement a generic debugger UI — it's to expose what fresco's runtime makes uniquely addressable.
- **Not a generic event-log library.** No abstraction-for-its-own-sake; the substrate operates concretely on fresco's `Journal`/`Event`/`Topology` types. If a future project wants similar primitives they can copy ~200 LoC.
- **Not a query language.** Nim API + `do:`-blocks. fresco already has heavy DSL surface that earns its keep; query helpers don't. (See "Q: DSL or plain Nim?" below.)
- **Not an IDE.** "The runtime is the IDE" is a logical extreme worth naming but explicitly not in scope.

## Premise

Three properties of fresco's substrate are load-bearing:

1. **Totally-ordered persistent journal.** Every reactive write, effect run, task spawn, restart, and supervisor decision is one entry in a log. Persistence is JSONL today; in-memory + tail-on-write to disk.
2. **The journal is the universal observability channel.** No state change happens out-of-band. The `journalEvent:` chokepoint in the runtime means every interesting transition is interceptable.
3. **Replay semantics in the substrate.** `rewindTo(N)` + `resumeLive` + snapshot/compaction (from #32 work) mean the system already knows how to project state to any point in history.

These properties, together, are unusual. Most reactive runtimes have *one* of them (Redux has the log; Elm has replay; Erlang has a supervision tree). Fresco has all three plus a contextvar substrate that makes per-task tracing free and a Concept-typed cap system that makes "what can this code do?" a first-class question.

The architectural principle this RFC enshrines: **the journal is the program's identity. Devtools is the surface that exposes that identity for query, manipulation, and replay. Everything we build on top is a renderer over that substrate.**

## The layered model

```
┌──────────────────────────────────────────────────────────┐
│  LAYER 4: manipulation (writes back to the substrate)    │
│  • rewriteable history    • predicate-armed triggers     │
│  • signal mutation via UI                                │
└──────────────────────────────────────────────────────────┘
                          ▲
┌──────────────────────────────────────────────────────────┐
│  LAYER 3: renderers (consumers of the substrate)         │
│  • panel (alt-screen)     • notebook (cellular IDE)      │
│  • sidecar (IPC)          • CI assertion (programmatic)  │
│  • bug-report artifact    • DOT/Graphviz export          │
└──────────────────────────────────────────────────────────┘
                          ▲
┌──────────────────────────────────────────────────────────┐
│  LAYER 2: overlay primitive (UI host integration)        │
│  • screen activation tracking — paused vs live           │
│  • foregrounded surfaces (modal, palette, devtools)      │
│  • hot-toggle as one application of the primitive        │
└──────────────────────────────────────────────────────────┘
                          ▲
┌──────────────────────────────────────────────────────────┐
│  LAYER 1: observability substrate (`fresco/obs`)         │
│  • query/select/project over journal+topology            │
│  • predicate primitives (sync + streaming)               │
│  • temporal: asOf, ancestors, descendants, windows       │
│  • topology traversal: supervisor tree, dep graph        │
│  • subscriptions (chronos-backed) for live consumers     │
└──────────────────────────────────────────────────────────┘
                          ▲
┌──────────────────────────────────────────────────────────┐
│  LAYER 0: existing fresco runtime (the substrate)        │
│  • Journal + Event + persistence                         │
│  • Supervisor + topology()                               │
│  • Computation/Signal dependency graph                   │
│  • rewindTo / resumeLive / snapshot                      │
└──────────────────────────────────────────────────────────┘
```

Each layer above depends only on layers below it. Renderers know nothing about each other; they all consume the substrate. Manipulation is a write-back path that re-enters the substrate at well-defined points.

## Layer 1: `fresco/obs` — observability substrate

The foundation. Pure Nim, no macros, fresco-specific.

### Surface (sketch)

```nim
import fresco/obs

# --- Selection over the journal --------------------------------------
let writes = j.events |> where it.kind == ekSignalWrite
let recent = j.events |> windowFromHead(100)
let myWrites = j.events
  |> where it.kind == ekSignalWrite
  |> where it.label == "count"

# --- Projection / aggregation ----------------------------------------
let perTask = j.events |> groupBy it.taskId
let labels = j.events |> distinctBy it.label

# --- Temporal --------------------------------------------------------
let snap = j.asOf(1042)             # journal state at index 1042
let chain = j.ancestorsOf(eventId)  # walks parentEvt links
let kids = j.descendantsOf(eventId)
let between = j.events |> window(1000 .. 1100)

# --- Topology traversal ----------------------------------------------
let allTasks = supervisors.flatTopology()
let restartCounts = supervisors.flatTopology() |> mapIt(it.restartCount)
let underAgent = supervisors |> subtree "agent"

# --- Dep graph -------------------------------------------------------
let depsOf = sig.observers              # who reacts to me
let triggers = comp.sources             # who I read from

# --- Subscriptions (streaming over chronos) --------------------------
let stream = j.subscribe(predicate = (proc(e: Event): bool =
  e.kind == ekSignalWrite and e.label == "count"))
await stream.nextMatch()

# --- Predicate-armed callbacks ---------------------------------------
let armed = j.arm do (e: Event) -> bool:
    e.kind == ekSignalWrite and e.value.parseInt > 1000
  do:
    asyncSpawn devtools.attachOn(j, sups, stream, screen)
defer: armed.disarm()
```

### Design notes for the substrate

**Composition style.** Pipeline operators (`|>`) over `seq[Event]` and friends. We're not introducing a new operator; Nim already has `|>` via templates in `std/sugar` or we use method-call chains. Either way: regular Nim, type-checked, IDE-completable.

**No DSL macro.** Considered and rejected. fresco's existing DSL macros (`receive:`, `region:`, `bindRows`, `supervisor:`, `tracked:`) earn their keep with semantic punch — race-then-cancel cleanup, bounds-checked region writes, capability discharge, dependency tracking. A query DSL would be pure syntactic sugar over `filterIt`/`mapIt`. Plain Nim wins on tooling (autocomplete, jump-to-def, stack traces point at the actual filtering step), type safety (typos are compile errors), and zero macro-debugging tax.

The one place a DSL could justify itself is *predicate-armed triggers*, where ergonomics matter:

```nim
# DSL (rejected):
on:
  kind == ekSignalWrite
  label == "count"
  value > 1000
do:
  panel.open()

# Plain Nim with do:-blocks (chosen):
j.arm do (e: Event) -> bool:
    e.kind == ekSignalWrite and e.label == "count" and
      e.value.parseInt > 1000
  do:
    panel.open()
```

The plain form is two extra lines, no macro to debug, and the predicate body is regular Nim that gets full type checking. The DSL form's appeal is shallower than it looks.

**Predicate evaluator.** When predicates are *authored interactively* (the REPL or notebook cells, not in source code), they're parsed as expressions in the restricted-DSL specified in `docs/rfc-devtools-experience.md` ("Predicate evaluator architecture"). When they're authored *in source code* (developer using `j.arm do (e) -> bool: ...`), they're regular Nim closures. The two are the same predicate-shape, but the in-source form uses Nim's full type checking and the interactively-authored form uses the restricted DSL with a registered-predicate extension for full-Nim escape. See the devtools-experience RFC for the DSL spec.

**Not generic.** The substrate operates concretely on `Journal`/`Event`/`Topology`. Extracting a generic "event log observability" library would require a concept/protocol that journals implement; fresco's `Event` is a kind-discriminated union with bespoke fields per variant, not a generic record. Generic abstraction would be pure overhead with zero second-consumer benefit.

**Subscription substrate.** Backed by chronos-native streaming primitives. New events flow through `journalEvent:` already; we attach an internal observer that fans out to subscribed `Future[Event]`s matching their predicates. Backpressure handled by the consumer (slow subscribers drop events with a warning, fast subscribers see everything).

### Implementation footprint

One file, `src/fresco/obs.nim`. Estimated ~250 LoC. Plus tests at `tests/unit/test_obs.nim`. Existing devtools panel (`src/fresco/devtools/panel.nim`) refactored internally to use the helpers — surface unchanged.

## Layer 2: overlay primitive (screen activation)

Today fresco's `Screen` model assumes one active surface writing to stderr at a time. Hot-toggle (or any overlay UI — modal, command palette, devtools) needs **multiple `Screen` values coexisting with one designated as "live."**

### Concept

- Each `Screen` carries an `active: bool` field
- Only one Screen at a time has `active = true`; that's the one whose diff-renderer writes to stderr
- A `withForeground(screen): body` template:
  - Saves the currently-active screen reference + alt-screen state
  - Marks `screen` as active; the host's screen as inactive
  - Forces a full repaint of `screen` into the alt-buffer
  - Runs `body`
  - On exit (every path): restores prior active, full-repaints the restored screen
- The host's reactive bindings *keep firing* while paused — they just don't paint. Their offscreen render targets stay current; on resume the diff against the screen's current contents is correct.

### Hot-toggle as an application

```nim
proc hostApp() {.async.} =
  let hostScreen = newScreen()
  withScope(rootScope):
    bindRows hostScreen.someRegion: ...

    while true:
      let key = await stream.nextKey()
      if key == Key(Ctrl, 'd'):
        let dtScreen = newScreen()
        withForeground(dtScreen):
          await runDevtoolsPanel(globalJournal, mySups, stream, dtScreen)
        # host screen reactivates here; full repaint via the with-template
      elif key == ...:
        ...
```

The overlay primitive isn't devtools-specific. The same machinery powers modal dialogs, command palettes, scrollback inspectors, log viewers. Solving hot-toggle properly = giving fresco a first-class **foregrounded surface** primitive that the rest of the kernel benefits from.

### Implementation footprint

Touches `src/fresco/screen.nim` (Screen gets an `active` field + paint-gating), introduces `withForeground` template. ~100–150 LoC including tests. The host-screen-keeps-firing-while-paused property is the tricky part and needs explicit testing (a bound widget mutates its source signal during the overlay; on resume the diff correctly shows the new state).

## Layer 3: renderers

Each consumes the substrate; none knows about the others.

> **The UX of each renderer is specified in `docs/rfc-devtools-experience.md`.** This section sketches what each renderer *is*; the experience RFC details what each *does* and what's novel about each. The two RFCs are tightly coupled.

### Panel (the existing thing, retrofitted)

Already exists as `runDevtoolsPanel`. Refactored internally to consume `fresco/obs` helpers instead of inline filtering. Surface unchanged.

### Embedded `attach()` helper

The one-liner for the common case ("my app has a `--devtools` flag, open the panel"). Pulls in cbreak + alt-screen + InputStream + Screen + `runDevtoolsPanel` + restore-on-every-exit-path. This is the small piece originally specified by #57's "embedded mode."

```nim
proc attach*(j: Journal, supervisors: seq[Supervisor]) {.async.}
proc attachOn*(j: Journal, supervisors: seq[Supervisor],
               stream: InputStream, screen: Screen) {.async.}
```

`attachOn` is the lower-level seam for tests + non-default-tty consumers.

### Notebook

A *notebook* is a list of *cells*; each cell is a query plan, a topology traversal, a scrubber session, or a free-form prose annotation. Cells are persistable as JSON (since plans are tagged-union data structures, not source code).

```nim
type
  CellKind = enum
    ckQuery        # journal+topology query
    ckScrubber     # replay session over a range
    ckProse        # markdown
    ckChart        # aggregated rendering of a query
  Cell = object
    kind: CellKind
    plan: QueryPlan    # for ckQuery
    range: Slice[EventId]  # for ckScrubber
    text: string       # for ckProse
    ...
  Notebook = object
    title: string
    cells: seq[Cell]
    schemaVersion: int
```

A notebook is loaded → cells execute against a journal → outputs are rendered (in a panel, or to stdout, or as a CI assertion). Cells can reference each other ("the chart in cell 5 uses the query from cell 3").

The novel artifact: **debugging sessions become version-controlled, reproducible, executable documentation**. Bug reports become saved notebooks. CI loads a notebook and asserts the prose-described behavior. Nobody does this for reactive programs.

### Sidecar

Out-of-process inspector. A separate `fresco-devtools` binary. Host opts in via `obs.publish(socketPath)`; sidecar connects, replays the persistent journal, then live-streams new events. The sidecar runs a notebook view against the streamed substrate.

Wire format: reuse the existing JSONL journal format for the replay phase + a small framed live-event channel for new events. Protocol versioning piggybacks on the existing journal schema version (`fresco/journal/persist.nim`).

Security: Unix socket with 0600 permissions, conventional location (`$XDG_RUNTIME_DIR/fresco-<pid>.sock`), no TCP. Authorization is filesystem permissions.

### CI assertion mode

Load a notebook in headless mode. Each cell that contains a query + an expected-output assertion runs as a test. Failure = CI failure. Lets you turn "I noticed this weird behavior while debugging" into "regression test that prevents this from happening again" by saving the notebook into the repo.

### DOT/Graphviz export

Dependency graph dumped as DOT. Pipe to `dot` and inspect in any browser. Trivial once `fresco/obs` exposes the graph in a queryable form.

## Layer 4: manipulation

The write-back paths. Where the substrate becomes interactive.

### Predicate-armed triggers

Already sketched in Layer 1's surface. Arming a predicate registers a callback on the journal's emission point. On match, the callback fires — `panel.open()`, `journal.snapshot()`, `notebook.runCell(N)`, anything.

Use cases:
- "Open devtools automatically when signal X exceeds threshold"
- "Take a snapshot whenever a supervisor restarts more than 3 times in 10s"
- "Send a Slack notification when a specific error class fires"
- "Halt execution at this point" (combined with `runtime.pause()`, future)

### Rewriteable history

`rewindTo(N)` projects state to event N; today, resuming jumps back to live. Extension: at event N, *modify* what a signal was set to, then replay forward. The system computes "what would have happened if signal X had value V at event N."

```nim
let edit = JournalEdit(
  atIndex: 1042,
  override: SignalWriteOverride(label: "count", value: "10"))
let projected = j.replayWith(edit)
# projected is a journal-like object showing what would have happened
```

This is what Light Table dreamed about. Fresco's journal-as-source-of-truth makes it possible because the journal *is* the canonical source for state — editing it edits reality (modulo any non-journal side effects, which the runtime explicitly avoids).

Caveats:
- Only signal writes are editable (effects/spawns/restarts are derived; editing them is undefined)
- Replay-with-edit is read-only against the live journal — it produces a projected view, never overwrites
- "Promote a replay-with-edit into the live journal" is a separate, sensitive operation (mutates current state; requires explicit user action; logged as a special event kind)

### Signal mutation from devtools

A panel/notebook displaying a signal can include a "mutate to value" action. Clicking it issues a normal signal write (journaled, observed by all dependents, fully reactive). This is the "live tweaking" workflow.

Combined with rewindTo: scrub to event 1042, mutate signal X to a new value, watch the projected forward replay. If you like the projection, commit it to the live journal (= make it actually happen now).

## Phasing

Order of implementation. Each phase is independently shippable. Each enables the next.

### Phase 1: substrate (`fresco/obs`)

Just Layer 1. Pure Nim helpers, no UI, no IPC. Existing panel refactored to consume it. Ships with full unit tests against synthetic journals.

**Issues**: `obs/` substrate, panel migration to obs.

### Phase 2: overlay primitive

Layer 2 alone. New Screen.active field, withForeground template, full repaint semantics. Tested via PTY harness with multiple Screens.

**Issues**: screen-activation tracking, withForeground primitive, paint-while-paused regression tests.

### Phase 3: minimal renderers

`attach()` + `attachOn()` (consolidates ex03's boilerplate). Predicate-armed triggers built on the obs subscription substrate. Hot-toggle as a demonstration of the overlay primitive — devtools open via Ctrl-D in a host app.

**Issues**: attach() helper, predicate-armed triggers, hot-toggle integration example.

### Phase 4: notebook substrate

The plan ADT, save/load, cell execution against a journal. Tested in isolation; the notebook UI (panel renderer for a notebook) comes after the data substrate.

**Issues**: notebook plan format, save/load, cell execution, CI assertion mode.

### Phase 5: rewriteable history

JournalEdit type, replayWith, projected-view rendering. Carefully tested for correctness (replay-with-edit must produce exactly what would have happened modulo edit).

**Issues**: JournalEdit primitive, replayWith semantics, projected-view UI in the panel.

### Phase 6: sidecar / IPC

Host-side `obs.publish`, sidecar binary, protocol implementation, security tests. Builds on the notebook (because the sidecar's UI is a notebook view consuming an IPC-streamed journal).

**Issues**: obs.publish, sidecar binary, IPC protocol, security model, packaging.

### Beyond this RFC

- Distributed multi-app journaling with causal ordering (Lamport-clock view across processes)
- `--ide` mode (full Smalltalk-style image)
- Recordable/replayable user-interaction sessions
- Predicate-armed *system pause* (halt execution on match, not just notify)

These are noted as future directions; explicitly out of scope for this RFC's milestone.

## Open design questions

### Q1: Notebook serialization format

Plans-as-data is the chosen approach (vs. plans-as-source-code-string). Format options:

- **Just JSON**: matches the existing journal serialization, easy to debug, version-control friendly
- **MsgPack**: faster, less debuggable
- **A textual notebook format** (like Jupyter's `.ipynb`): JSON-encapsulated, includes prose

Lean: JSON for v0, with a notebook file extension (`.fnb` for "fresco notebook"). Mirror Jupyter's structure (cells = list of typed records) for familiarity.

### Q2: Hot-toggle screen activation — what happens to host reactive bindings during pause?

Two options:

- **Bindings keep firing, paint to offscreen targets only.** When host resumes, the diff against the screen-restored alt-buffer is correct. Cheaper for resume (small diff usually), more expensive during overlay (host's CPU isn't idle).
- **Bindings pause (don't fire) during overlay.** Cheaper during overlay, but on resume the host needs to re-fire all bindings to catch up — and any reactive state that changed externally (e.g., from a sub-task spawned by devtools) might not propagate correctly.

Lean: bindings keep firing. The "bound widget mutates its source during overlay" test pins this property. CPU-during-overlay is fine because the overlay is transient.

### Q3: Sidecar IPC framing — JSONL stream or framed binary?

The replay phase reuses persistent-journal JSONL (already exists). The live phase needs new framing.

- **JSONL line-stream over the same socket**: simplest, debuggable with `nc`, matches replay format
- **Length-prefixed binary frames (MsgPack or similar)**: faster, more robust to partial reads

Lean: JSONL line-stream. Throughput isn't the bottleneck (~1k events/sec is generous for a devtools sidecar); debuggability matters more.

### Q4: Predicate-armed-trigger lifetime

Arming a predicate registers a callback inside fresco's runtime. Lifecycle questions:

- Tied to a scope (disposes when scope disposes)?
- Tied to a `defer armed.disarm()` block?
- Process-global until explicit disarm?

Lean: tied to a scope by default (matches the rest of fresco's resource-management convention), with `defer armed.disarm()` as the explicit form when scopes don't fit.

### Q5: Rewriteable history — semantics of effects during replay-with-edit

An edit changes a signal at event N. Effects that read that signal AT or AFTER N would have fired with different values. Replay-with-edit must re-run those effects in projection.

Question: are effect side-effects (e.g., spawning a sub-task, journaling) re-executed in the projection, or simulated?

Lean: projection runs effects in a *sandbox* — a parallel scope tree that's discarded after the projection is rendered. The live journal/scope tree is untouched. "Promoting" a projection requires explicit user action: copy the projection's events into the live journal.

This is the *most architecturally significant* open question and probably the most expensive phase to implement correctly.

### Q6: CI assertion mode — what does "assert" mean for a query?

A cell can assert that its query produces an expected output. Forms:

- "Result count equals N"
- "Result set is exactly { ... }" (deep equality)
- "Result subset includes { ... }"
- "Result matches pattern (regex)"

Lean: start with count + deep equality. Pattern matching comes later if real notebooks need it.

## Migration / compatibility

No public-API breaks. The existing `runDevtoolsPanel` stays as-is and continues working. New surface is purely additive:

- `fresco/obs` is new
- `Screen.active` is new (defaults to true; existing callers see no change)
- `attach()` is new
- All renderers beyond panel are new

The panel's internal refactor to use `fresco/obs` is invisible to consumers.

## Why this scope

Six phases is a lot. Three reasons it's still the right framing:

1. **Each phase is independently valuable.** Shipping just Phase 1 (the substrate) already pays for itself by making the existing panel cleaner and enabling everything else. We're not committing to phases 2–6 by shipping phase 1.

2. **The full vision constrains the substrate design.** Knowing phases 4 (notebook) and 6 (sidecar) are coming means the substrate's subscription model has to be transport-flexible from day one. Designing the substrate without that knowledge would force a Phase 4 rewrite. Writing the full RFC now prevents that.

3. **No consumers means we get to be principled.** fresco has no production users to break. This is exactly the kind of work that becomes painful if deferred until consumers exist; pre-consumer is when the substrate can be designed properly.

## What's not in this RFC

- The `--ide` Smalltalk-style maximalism. Noted; deferred indefinitely.
- A new query language with parser+evaluator. Considered and rejected.
- Generic event-log library extraction. Considered and rejected.
- A specific notebook UI. The data substrate is here; the panel-as-notebook renderer is a separate cycle.
- Distributed multi-process observability. Noted as a future direction; depends on Phase 6 IPC being usable as a primitive.

## Decision log

(Empty initially. Decisions made during implementation get appended here as they happen, with rationale.)
