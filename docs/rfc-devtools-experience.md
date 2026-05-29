# RFC: Devtools experience — the novel surface, in concrete UX terms

**Status**: Draft
**Author**: Corey Leavitt
**Companion to**: `docs/rfc-reactive-observability.md` (substrate), `docs/rfc-consistency-model.md` (verification source), `docs/rfc-terminal-interaction.md` (rendering substrate)

## Why this RFC exists

The reactive observability RFC defines the substrate that powers devtools — queries, predicates, subscriptions, the journal-as-source-of-truth, the static dep graph. What it deliberately leaves underspecified is the *experience*: what does the user see, how do they interact, what's the novel UX claim?

The substrate without the experience is a library nobody adopts. fresco's devtools are not generic; they're capable of things no other reactive runtime can ship because they exploit fresco-specific substrate properties (journal totally-ordered, replay deterministic, cap concept system static, dep graph compile-time-extracted). This RFC specifies what those things look like to a user, why each is novel, and what the implementation surface needs to be.

The promise: a fresco app developer using these devtools should feel that they're using something *qualitatively different* from what any other reactive UI library offers — not a "panel that shows you state" but a programmable, time-travel-capable, verification-aware introspection environment.

## Design principles

### 1. The panel is the default surface; the notebook is the persistence layer; the sidecar is the remote surface; the CI mode is the verification surface. All four consume the same substrate.

No "devtools" is a single artifact. The devtools experience is a constellation of surfaces, each appropriate for a different use case, all driven by the same underlying queries and predicates. A predicate authored in the panel can be saved to a notebook can be replayed in CI can be exported to the sidecar.

### 2. Every surface is interactive by default; static rendering is the exception.

State changes. The reactive substrate updates. The devtools must reflect that without manual refresh. Even the CI assertion mode "runs" the notebook against an input journal — the assertion is the dynamic result of static-looking cells.

### 3. Novel features come first in the layout; conventional features are quietly available.

If you open the panel and the first thing you see is "task tree + log scroll," that's a generic debugger. If the first thing you see is the branching time-travel graph with the current journal head pinned and forkable, you're using fresco's devtools. The novel UX claims are foregrounded.

### 4. Devtools is a real fresco app, not a special case.

The panel is built using fresco's own region/binding/receive/hotkey machinery. It's dogfood. It runs under intonaco's supervisor + cap system. This isn't an aesthetic choice — it's a forcing function. Anything painful about building the devtools panel reveals roughness in fresco itself.

### 5. The experience scales with the substrate.

As research RFCs land (consistency / glitch-freedom, substructural caps, refinement types, guarded productivity), their static analysis results surface as new devtools views automatically. The devtools experience grows along with what intonaco can prove.

## The ten novel features

Each section: what it is, motivating scenario, concrete UI sketch, interaction model, implementation notes.

### 1. Branching time-travel

**What it is.** Scrub backward through the journal to any past event. Fork the state at that point into a sandboxed replay. Edit a signal value in the sandbox. Watch what would have happened. Multiple forks open simultaneously, each a separate "what-if" branch over the same journal range.

Conventional time-travel debuggers (Elm Debugger, Redux DevTools) let you replay state. None let you *branch*. The combination of fresco's journal-as-source-of-truth + replay-with-edit + sandboxed projection (from research RFCs) makes this possible.

**Motivating scenario.** You see a bug. You scrub back 50 events to where it started. You think the cause was `userInput = "x"` at event 1042; you want to test by setting it to `"y"` instead. Today: you'd have to rerun the entire session with a different input. With branching time-travel: fork at event 1042, edit the value, see the alternate timeline render in a side panel. If the bug doesn't reproduce, you've located the cause.

**Concrete UI sketch.**

```
 ┌─Journal Timeline─────────────────────────────────────────────────┐
 │                                                                  │
 │  ████████████████████████████████████████████ HEAD               │
 │  └─event 0                  ▲                  └─event 1247      │
 │                             │                                    │
 │                             └─pinned cursor at event 1042        │
 │                                                                  │
 │  ┌─Fork A (signal:userInput = "y")────────────────────────────┐  │
 │  │  ████████████████████████░░░ diverges at 1043              │  │
 │  │  └─renders in pane #2 ──────────────────────────────────── │  │
 │  └────────────────────────────────────────────────────────────┘  │
 │                                                                  │
 │  ┌─Fork B (signal:retries = 0)────────────────────────────────┐  │
 │  │  ███████████████████░░░░░░░ diverges at 1043               │  │
 │  │  └─renders in pane #3 ──────────────────────────────────── │  │
 │  └────────────────────────────────────────────────────────────┘  │
 └──────────────────────────────────────────────────────────────────┘
```

The actual journal renders as a continuous bar. Pinned cursor marks the fork point. Forks render as separate bars that diverge from the cursor; their projected state renders in side panes.

**Interaction model.**

- `←`/`→` scrub one event
- `Shift+←`/`Shift+→` scrub 10 events
- `Enter` pin cursor at current event
- `f` open fork dialog (select signal to edit, enter new value)
- `Tab` cycle between live view and each open fork's projection
- `q` close current fork
- `r` resume live (clears all forks, returns to HEAD)

**Implementation notes.** Depends on the rewriteable-history research RFC (`replayWith` and the sandboxed projection machinery). Multiple concurrent sandboxes — each fork is its own short-lived scope with its own observable graph. Fork views render to separate Regions in the panel layout.

### 2. Causal-chain navigation as primary UI

**What it is.** Every event in the journal carries `parentEvt` — the event that caused it. Click any event; the panel walks backward through the causal chain, displaying the causation tree. Stack traces show *where in code*; causal chains show *why in time*.

**Motivating scenario.** Effect fires; the panel shows it; you don't know why. You click. The panel walks back: "this effect fired because `count` was written by `handleClick` because the user pressed `Space` at event 943." Five clicks, you've traced the bug to its origin.

**Concrete UI sketch.**

```
 ┌─Causal Chain (event 1247)────────────────────────────────────────┐
 │                                                                  │
 │  ekEffectFired   #1247  "render donut" task:t12 [3ms ago]        │
 │       ↑                                                          │
 │  ekSignalWrite   #1244  "ctx_used = 4200" task:t9 [4ms ago]      │
 │       ↑                                                          │
 │  ekSignalWrite   #1241  "tokens_consumed = 100" task:t9 [5ms ago]│
 │       ↑                                                          │
 │  ekToolCall      #1238  "openFile" task:t9 [7ms ago]             │
 │       ↑                                                          │
 │  ekUserInput     #1230  "send message" task:t1 [12ms ago]        │
 │       ↑                                                          │
 │      ROOT  (no parent)                                           │
 │                                                                  │
 │  [Tab] expand siblings    [Enter] focus event    [c] copy chain  │
 └──────────────────────────────────────────────────────────────────┘
```

Vertical chain with arrows showing causation direction. Each row: event kind + ID + summary + task ID + relative timestamp. Tabbing into a row expands its sibling events (other things the same parent caused). Focusing an event pivots the chain to that event as the new starting point.

**Interaction model.**

- Click (or `Enter`) any journal event opens the causal chain
- `↑`/`↓` walk the chain
- `Tab` expand siblings of the focused event
- `Enter` pivot — make this event the new chain root
- `c` copy chain as text (for bug reports)

**Implementation notes.** Substrate primitive: `j.ancestorsOf(eventId)` (already exists). Devtools just renders it interactively. The sibling-expansion uses `j.descendantsOf(eventId.parent)` minus the focused child.

### 3. Static graph + runtime trace, overlaid

**What it is.** The static dependency graph (from the C-shape explicit-deps walker) is known at compile time. The runtime journal shows which graph edges fired and when. Render the graph; color/thicken edges by recent firing frequency.

You can see your reactive program's structure AND its dynamic behavior in one view. No other library has this because no other library has compile-time graph extraction.

**Motivating scenario.** You think your UI is slow because too many signals re-fire. With this view: render the static graph, hover over recent activity. The signals with thick, bright-red edges are the hot path. Optimization target visible.

**Concrete UI sketch.**

```
 ┌─Dep Graph (recent: last 5s)──────────────────────────────────────┐
 │                                                                  │
 │                                                                  │
 │     userInput ●═════════╗  hot edge: 28 fires/s                  │
 │                         ║                                        │
 │                         ╠══> parseInput ●═════╗                  │
 │                         ║                     ║                  │
 │                         ╠══> validateInput ●  ║                  │
 │                                                ║                 │
 │     timer ─────────────────> currentTime ●════╝══> renderHeader  │
 │                                                                  │
 │     theme ─────────────────────────────────────> renderPill      │
 │                                                                  │
 │     ■ = signal (filled when value changed recently)              │
 │     ─ = static edge (compile-time dep)                           │
 │     ═ = static edge that fired this window                       │
 │     thickness = firing frequency (last 5s window)                │
 │                                                                  │
 │  [g] toggle window     [Enter] focus node     [q] back           │
 └──────────────────────────────────────────────────────────────────┘
```

ASCII-art graph laid out by some auto-layout. Static structure shown as thin lines; runtime activity shown as thickness / color / animation. The example shows `userInput` fanning out heavily (28 fires/sec) while `theme` is a static edge that hasn't fired.

**Interaction model.**

- Click a node opens its details (current value, observer list, recent writes)
- `g` cycle through time windows (1s, 5s, 30s, all-time)
- `f` filter to one task's subgraph
- `h` highlight a specific signal's transitive closure

**Implementation notes.** Static graph from the C-shape walker extracted at compile time (already exists in intonaco's `noUndeclaredSignals` infrastructure). Runtime firing counts come from a side-table the journal maintains. Graph layout is the hard part — terminal layout of an arbitrary directed graph is genuinely tricky; punt to a simple force-directed layout that's good-enough for typical apps (~100 nodes).

### 4. Cap-flow visualization

**What it is.** No other reactive library has compile-time cap discharge. The devtools surface this by rendering the supervisor tree with cap grants annotated. Click any code path to see which caps it holds and where each came from.

**Motivating scenario.** You're writing an AI agent. Tool `t1` works; tool `t2` mysteriously doesn't (it's missing a cap). With this view: select `t2` in the panel; the cap-flow view shows it's missing `NetworkCap`; the supervisor tree highlights where `NetworkCap` was granted and where it wasn't propagated. You see the gap visually.

**Concrete UI sketch.**

```
 ┌─Cap Flow──────────────────────────────────────────────────────────┐
 │                                                                   │
 │                                                                   │
 │   rootSupervisor  [FsReadCap, FsWriteCap, ProcessCap]              │
 │     │                                                             │
 │     ├── agentSupervisor  [+ NetworkCap, + ToolDispatchCap]        │
 │     │     │                                                       │
 │     │     ├── userInputHandler   (no needs)                       │
 │     │     │                                                       │
 │     │     └── toolDispatcher                                      │
 │     │           │   {.needs: (NetworkCap, FsReadCap).}            │
 │     │           │   ✓ NetworkCap ← agentSupervisor (line 42)      │
 │     │           │   ✓ FsReadCap ← rootSupervisor (line 8)         │
 │     │           │                                                 │
 │     │           ├── tool_t1  {.needs: NetworkCap.}                │
 │     │           │     ✓ NetworkCap ← agentSupervisor (line 42)    │
 │     │           │                                                 │
 │     │           └── tool_t2  {.needs: (NetworkCap, SecretCap).}   │
 │     │                 ✓ NetworkCap ← agentSupervisor (line 42)    │
 │     │                 ✗ SecretCap  ← NOT GRANTED [bug source]     │
 │     │                                                             │
 │     └── uiSupervisor  [+ TerminalCap, + TruecolorCap]             │
 │           │                                                       │
 │           └── renderTask                                          │
 │                 ✓ TerminalCap ← uiSupervisor (line 67)            │
 │                                                                   │
 │  [Tab] focus next      [Enter] jump to grant site                 │
 └───────────────────────────────────────────────────────────────────┘
```

Supervisor tree with each node's grants. Children inherit their parent's grants. Each leaf task shows its `{.needs.}` requirements; each requirement either resolves (`✓`, with origin) or fails (`✗`, marked as bug source). Click the `✗` opens the source location where to add the missing `provides(...)`.

**Interaction model.**

- `↑`/`↓` walk tasks
- `Tab` next missing-cap location
- `Enter` jump to source file at the resolving (or missing) provide site
- `r` re-discharge (rebuilds the tree with current code)

**Implementation notes.** Cap tree is extracted from the supervisor object's type (the concept-typed grant fields). procRequiresNames provides the consumer-side needs. The substrate already has all of this; the work is rendering it.

### 5. Verification view

**What it is.** As research RFCs land (consistency / glitch-freedom, substructural caps, refinement types, guarded productivity), their verification results surface in the panel — compile-time-checked, with consistency additionally reporting how much of the graph is statically scheduled vs handled by the runtime dynamic tier. Each verification is a green checkmark or a red error annotation. Devtools becomes the user-facing surface for the substrate's correctness claims.

**Motivating scenario.** You're building a reactive UI and want to know: can any value ever be read half-updated? You open verification view; consistency shows a green check when the scheduler guarantees it, and a value that depends on itself, or a value-rule violation, is highlighted with the offending site and a plain-language fix.

**Concrete UI sketch (L0 — default; glossary terms only, no internal vocabulary).** Per the consistency RFC's `intonaco/verification` contract, the default surface uses developer-facing terms; raw internals (`height`, `SCC`, `Monotonic[int]`, `linear`) appear only under the `x` expert toggle.

```
 ┌─Verification Status───────────────────────────────────────────────┐
 │                                                                   │
 │  ✓ Consistency        no value can be read half-updated            │
 │                       3 sources safe to merge in any order         │
 │                                                                   │
 │  ✗ Productive loops   1 value depends on itself with no guard      │
 │       └─ total (line 142) — add a `next` guard, or break with peek │
 │       └─ [Enter] jump to source                                    │
 │                                                                   │
 │  ✓ Capabilities       all requirements satisfied; none over-used   │
 │                                                                   │
 │  ⚠ Value rules        1 forbidden write                            │
 │       └─ counter (line 87) — may only increase; this decrements    │
 │                                                                   │
 │  [j/k] issue  [Tab] category  [l/h] expand/collapse  [x] expert    │
 └───────────────────────────────────────────────────────────────────┘
```

Each row is a checker from the shared `Diagnostic` contract; failures expand (`l`) to the `{symptom · site · rule · fix}` grammar. The `x` expert toggle reveals L2 internals (computed heights, SCC membership, raw refinement types) behind a visible `[expert]` indicator.

**Interaction model (two axes — see consistency RFC "Devtools TUI").**

- `j/k` move between issues; `Tab/S-Tab` cycle categories
- `l/h` deepen / collapse (L0 ✓ → L1 issue+site → fix detail); L0 never auto-expands
- `x` toggle L2 expert internals (`[expert]` indicator shown)
- `Enter` jump to source; `c` copy issue in the bug-report grammar; `r` re-verify
- `r` force re-verify

**Implementation notes.** Each research RFC's static analysis produces results that the panel queries. The protocol: each RFC exposes a `verificationResults(): seq[Issue]` proc; the panel aggregates and renders. As new research RFCs land, they plug in by extending this protocol.

### 6. Replay-with-edit + diff overlay

**What it is.** A specific application of branching time-travel: fork the replay with an edit, then render both runs (actual + alternate) side-by-side with the divergence highlighted. A/B testing for runtime behavior, visualized.

**Motivating scenario.** "If `count` had been 10 instead of 5, what would the UI have shown?" Set up the edit, the panel renders both versions in adjacent panes with deltas highlighted (chars that differ are colored, regions that changed are bordered).

**Concrete UI sketch.**

```
 ┌─Actual (event 1042: count = 5)─┐  ┌─Alternate (count = 10)──────┐
 │                                │  │                              │
 │  Count: 5                      │  │  Count: 10  ◀── delta        │
 │  ████████░░░░░░░░░░░░░░  50%   │  │  ██████████████████  100%   ◀│
 │  Status: working               │  │  Status: complete  ◀── delta │
 │                                │  │                              │
 │                                │  │                              │
 └────────────────────────────────┘  └──────────────────────────────┘
                                                                     
 [delta-list]                                                        
   - "Count: 5" → "Count: 10"                                        
   - bar width 8 → 18                                                
   - status "working" → "complete"                                   
                                                                     
 [<] back to single view    [a] toggle annotations    [Enter] commit
```

Two panes side-by-side with the same Region structure. Cells that differ between actual and alternate are visually marked (background color, border). A delta list at the bottom summarizes the differences. "Commit" promotes the alternate run's events into the live journal (irreversible; warned).

**Interaction model.**

- `<` exit dual view
- `a` toggle annotations (diff markers on/off)
- `Enter` commit the alternate run (with confirmation)
- `Tab` switch focus between panes

**Implementation notes.** Depends on the rewriteable-history RFC. Two render passes against two render targets (actual vs sandbox). Diff computation between the two target buffers happens per-paint cycle.

### 7. Predicates as code-as-artifact

**What it is.** Devtools predicates are not toggle UI; they're saved Nim expressions inside notebook cells. Version-controllable. Code-reviewable. Shareable as a unit. A predicate that fired the bug becomes part of the regression test suite as-is.

**Motivating scenario.** You hunted down a flaky bug with a predicate that fires when `count > 1000 && taskId == agent`. The predicate finds the bug. You save it to a notebook cell. The notebook gets committed. CI runs the notebook; it asserts that the predicate never fires under normal workload. Future code that re-introduces the bug fails the test.

**Concrete UI sketch (in the notebook cell view):**

```
 ┌─Notebook: tools/regression-issue-247.fnb───────────────────────────┐
 │                                                                    │
 │  Cell 1 (prose):                                                   │
 │    # Regression test for issue #247                                │
 │    Counter occasionally exceeds 1000 under agent workload.         │
 │                                                                    │
 │  Cell 2 (predicate):                                               │
 │    let pred = proc(e: Event): bool =                               │
 │      e.kind == ekSignalWrite and                                   │
 │      e.label == "count" and                                        │
 │      e.value.parseInt > 1000 and                                   │
 │      e.taskId == "agentLoop"                                       │
 │                                                                    │
 │  Cell 3 (query):                                                   │
 │    let matches = j.events |> where pred                            │
 │                                                                    │
 │  Cell 4 (assertion):                                               │
 │    assert matches.len == 0,                                        │
 │      "count exceeded 1000 — issue #247 regression"                 │
 │                                                                    │
 │  [Run notebook]    [Save]    [Export to CI]                        │
 └────────────────────────────────────────────────────────────────────┘
```

Cells are typed (prose, predicate, query, assertion, chart). Each is a Nim expression / block / markdown. The notebook is a `.fnb` file (JSON, see below). "Run notebook" executes against current state; "Export to CI" generates a nimble-task entry.

**Interaction model.**

- Cells navigated by arrow keys
- `Enter` enters edit mode on focused cell
- `n` insert new cell below
- `D` delete cell
- `Ctrl+s` save
- `Ctrl+r` run

**Implementation notes.** Notebook format: JSON list of typed cells. Each cell stores its source text + cell-kind tag. Predicate cells get evaluated as Nim closures at notebook-load time; the notebook engine compiles them (Nim VM or actual compile) — implementation choice deferred.

### 8. Notebook-as-bug-report

**What it is.** Bug reports stop being unstructured text. They become saved notebooks: a journal range + cells demonstrating the bug + prose explanation + failing assertions. The notebook IS the reproduction. Load it; the assertions fail; fix; the assertions pass.

**Motivating scenario.** A user files an issue. They include a `.fnb` file. The maintainer downloads it, loads it in their devtools, the assertions fail in exactly the same way. The maintainer fixes the bug; re-runs the notebook; assertions pass. Notebook gets committed to the repo's regression suite.

**Concrete UI sketch:** same as cell 7 above (predicates are how bug-report notebooks work); the difference is content (a bug report notebook leads with prose explaining the bug, has predicate cells that capture the bug condition, has assertions that fail).

**Implementation notes.** Notebooks reference journal segments. A "self-contained" notebook also embeds a journal snippet (events between two timestamps) so the assertions can be evaluated without the reporter sharing their full journal. This is the artifact users commit and share.

### 9. Observation-driven test generation

**What it is.** Record an interaction session in devtools. Extract the journal range. Generate a regression test that asserts the same sequence reproduces. "I just demonstrated the workflow; now there's a test that ensures it stays demonstrable."

**Motivating scenario.** You manually clicked through a complex 12-step workflow. It works. You hit `Ctrl+G` (generate test). The devtools writes a notebook to `tests/regressions/workflow_NNN.fnb` containing: the journal segment of those 12 steps + assertions for each rendered state along the way. Future runs of the test must reproduce the same sequence.

**Concrete UI sketch.**

```
 ┌─Test Generation──────────────────────────────────────────────────┐
 │                                                                  │
 │  Session range: event 982 → event 1247  (265 events)             │
 │                                                                  │
 │  Detected interactions:                                          │
 │    - 5 user input events                                         │
 │    - 23 signal writes                                            │
 │    - 12 effect fires                                             │
 │    - 3 mount/dispose cycles                                      │
 │                                                                  │
 │  Generate:                                                       │
 │   [×] Input replay (run inputs through fresco, assert journal    │
 │       matches)                                                   │
 │   [×] Final-state assertion (assert specific signal values at    │
 │       end)                                                       │
 │   [ ] Per-step screenshot (capture rendered output at each step  │
 │       — expensive, opt-in)                                       │
 │                                                                  │
 │  Output: tests/regressions/workflow_042.fnb                      │
 │                                                                  │
 │  [Generate]    [Cancel]                                          │
 └──────────────────────────────────────────────────────────────────┘
```

A dialog showing what was recorded and what test variants are available. The output is a notebook that, when run, asserts the recorded behavior reproduces.

**Implementation notes.** Depends on headless driver (for replay-without-terminal). Depends on notebook format. The test "reproduces" by feeding the recorded input events back into the app and asserting the journal matches.

### 10. Live REPL into the reactive graph

**What it is.** Devtools has a Nim expression input. Type an expression; it evaluates against current signal state. Smalltalk-style live inspection.

**Motivating scenario.** "What's the current value of `count() * 2`?" Type it in the REPL. See the result. "Set `count` to 50." Run a statement. UI updates everywhere `count` is bound. Live experimentation against running state.

**Concrete UI sketch.**

```
 ┌─REPL─────────────────────────────────────────────────────────────┐
 │                                                                  │
 │  fresco> count()                                                 │
 │    => 42                                                         │
 │                                                                  │
 │  fresco> count() * 2                                             │
 │    => 84                                                         │
 │                                                                  │
 │  fresco> {.needs: StateMutCap.}: count.set(100)                  │
 │    => () [signal write recorded as event 1248]                   │
 │                                                                  │
 │  fresco> taskTopology()                                          │
 │    => @[                                                         │
 │         {name: "agentLoop", state: running, restarts: 0},        │
 │         {name: "renderTask", state: running, restarts: 0}        │
 │       ]                                                          │
 │                                                                  │
 │  fresco> _                                                       │
 │                                                                  │
 │  [Esc] back to panel    [↑] history    [Tab] complete            │
 └──────────────────────────────────────────────────────────────────┘
```

A text-input prompt at the bottom of the panel. Expressions evaluate against current state. Statements with cap requirements show their `{.needs.}` in the prompt. Tab-completion based on declared signals.

**Implementation notes.** Hardest implementation: requires a Nim expression evaluator that runs in-process. Options: Nim VM (slow but works), JIT macro re-compile (faster but complex), or restricted expression subset (subset of Nim — `signalName()`, `signal.set(value)`, basic arithmetic — that can be parsed and evaluated by a small interpreter we ship). Lean: restricted subset for v0; full Nim eval for v1.

## The five renderers

The ten novel features above are surfaced through five render contexts.

### Panel (default, in-process)

The existing `runDevtoolsPanel` evolves into a multi-view panel:
- Press `1`-`9` to switch between views (time-travel, causal chain, dep graph, cap flow, verification, replay/diff, notebook, REPL)
- Hot-toggle from host app via Ctrl+D (uses the overlay primitive from the terminal RFC)
- All views share the same underlying substrate (queries + predicates + journal)

### Notebook (persistence, sharable artifact)

A `.fnb` file. JSON. List of typed cells. Loadable / runnable / saveable. Sharable as bug reports, regression tests, debugging-session-as-documentation.

### Sidecar (out-of-process)

A separate `fresco-devtools-sidecar` binary. Connects to a running app's published journal over Unix socket. Same view set as the panel, fed from the IPC-streamed substrate instead of in-process queries. Operator's tool for production observation.

### CI assertion mode (headless)

Notebooks loaded by a nimble task. Cells with assertions execute against the journal/state captured at test time. Failures are CI failures. Output is structured (JSON) for CI integration.

### Hot-toggle overlay (transient)

Built on the overlay primitive (terminal RFC). Ctrl+D in any fresco app pauses the host UI and opens the devtools panel inline; press `q` returns to the host. Same panel views as the standalone version; ephemeral state (no save unless explicitly saved to notebook).

## Predicate evaluator architecture

Three places in this RFC depend on evaluating user-authored expressions at runtime: predicate-armed triggers, the live REPL, and CI-assertion-mode notebook cells. There are three viable implementation strategies, each with real tradeoffs. We commit to a specific architecture here so all three consumers use the same evaluator.

### Decision: ship a restricted expression DSL with a registered-predicate extension point

We define `intonaco/predexpr` — a small expression language designed for predicate-/query-shaped use, evaluated by a hand-written interpreter living in intonaco. Not full Nim. The deliberate-restriction tradeoff:

**What it supports (the 90% case):**
- Signal reads — `signalName()` returns current value of a known signal
- Field access — `event.kind`, `event.label`, `event.value`, `event.taskId`, `event.parentEvt`
- Comparisons — `==`, `!=`, `<`, `>`, `<=`, `>=`
- Boolean logic — `and`, `or`, `not`, parentheses
- Arithmetic — `+`, `-`, `*`, `/`, `%` over int/float
- String operations — `startsWith`, `endsWith`, `contains`, `len`, indexing
- Casts — `parseInt`, `parseFloat`, `$` (to string)
- Calls to *registered* predicates — `myCheck(event)` works if `myCheck` was registered

**What it doesn't support:**
- Arbitrary Nim code
- Closures, recursion, side effects
- Type definitions
- Module imports
- Generics

**The extension point**: anything not expressible in the restricted DSL can be implemented as a Nim proc and registered:

```nim
# In the user's app code:
registerPredicate "matchesAdminRegex", proc(e: Event): bool =
  let pattern = re"^/admin\s+"
  e.value.match(pattern)

# In a notebook cell:
let matches = j.events |> where matchesAdminRegex(event)
```

The user gets full Nim power for the parts that need it (regex, library calls, complex logic), while the DSL handles the common case of "compare fields, combine with boolean logic, check thresholds."

### Why a restricted DSL over the alternatives

**vs Nim VM**: VM startup time is multi-second; would make notebook load painful. VM is missing some Nim features (FFI, certain macros). Marshalling between VM types and host types is non-trivial. For predicate-shape use, restricted DSL is faster to evaluate and has zero startup overhead.

**vs compile-on-load**: requires the user's machine to have the Nim compiler installed, which is fine for developers but rules out "share a notebook with someone who doesn't develop Nim." Killed the portability claim of bug-report-as-notebook. The restricted DSL evaluates anywhere the fresco runtime runs.

**vs full Nim**: not actually an option without one of the above mechanisms. Pursuing it adds substantial complexity for marginal gain when the registered-predicate extension covers the cases the DSL can't.

### Restricted DSL is consistent with fresco's voice

fresco already ships restricted DSLs throughout: `receive:`, `region:`, `bindRow`, `bindRows`, `bindCollection`, `computed`/`effect`, `supervisor:`, `cap`, `provides`, `child`, etc. Each is a small language that compiles to Nim. The predicate DSL fits the project's style — a small purpose-built language solving a specific shape of problem, with full-Nim escape via registration.

### Implementation footprint

- `intonaco/predexpr/` — module containing parser + AST + interpreter
- Lexer/parser: ~400 LoC of hand-written code (or use a small parser combinator library)
- Interpreter: ~300 LoC (tree-walking interpreter; tail-recursion isn't a concern for predicate-shape expressions)
- Registration machinery: ~100 LoC (named registry + invocation glue)
- Tests: ~600 LoC

Total: ~1400 LoC for a fully working evaluator. Manageable.

### Where this surfaces in the RFCs

- **Predicate-armed triggers** (substrate side, observability RFC): `j.arm` takes a DSL expression as a string OR a registered-predicate name OR a Nim closure. The string-DSL path is the cross-RFC unifying surface.
- **Live REPL** (this RFC, feature 10): the input prompt parses the DSL on submit. The "fresco>" prompt evaluates DSL expressions; `:nim` prefix switches to invoking a registered Nim helper.
- **Notebook cells** (this RFC + observability): predicate cells, query cells, and assertion cells all hold DSL source. CI assertion mode evaluates them headlessly.

All three use the same parser, the same evaluator, the same registration mechanism. One implementation, three surfaces.

## Notebook format spec

`.fnb` file = JSON object:

```json
{
  "schemaVersion": 1,
  "title": "Regression test for issue #247",
  "description": "Counter occasionally exceeds 1000 under agent workload.",
  "cells": [
    {"kind": "prose", "content": "# Regression test for issue #247\n..."},
    {"kind": "predicate", "content": "proc(e: Event): bool = ..."},
    {"kind": "query", "content": "let matches = j.events |> where pred"},
    {"kind": "assertion", "content": "assert matches.len == 0, \"...\""},
    {"kind": "chart", "content": "donut(value = ..., ...)", "outputType": "rendered"}
  ],
  "journalEmbedded": "events_982_to_1247.jsonl",
  "metadata": {
    "frescoVersion": "0.x.y",
    "createdAt": "2026-05-20T15:30:00Z",
    "author": "..."
  }
}
```

Cell kinds:
- `prose` — Markdown
- `predicate` — Nim closure expression
- `query` — substrate query expression (returns a value)
- `assertion` — Nim expression that must evaluate truthy or fails the notebook
- `chart` — a render-output cell (its content is rendered to display, not evaluated for value)

`journalEmbedded` (optional) — path to an embedded journal slice for self-contained reproduction.

## Sidecar binary spec

`fresco-devtools-sidecar /run/user/.../app.sock`

Behavior:
1. Connect to socket
2. Handshake (protocol version, journal schema version)
3. Replay phase: receive journal-up-to-current-head as JSONL stream
4. Live phase: receive new events as they're emitted
5. Render: same panel UI as the in-process devtools, fed by streamed data instead of direct journal access

Substrate same as in-process devtools. The only difference is data source.

## CI assertion mode spec

```nimble
task notebook, "Run a devtools notebook as a regression test":
  let path = paramStr(2)
  exec "fresco-devtools-cli run " & path
```

Runs the notebook headless. Output is JSON to stdout describing each cell's evaluation result. Assertion failures non-zero exit. CI integration via standard test reporters.

## Phasing

Aligned with the observability RFC's phasing, but with explicit UX deliverables at each phase:

**Phase 1**: Substrate (`intonaco/obs`) — queries, predicates, subscriptions. UX deliverable: existing panel refactored to use the substrate.

**Phase 2**: Predicate-armed triggers + REPL. UX deliverable: predicates can be authored in panel and trigger callbacks; REPL view live.

**Phase 3**: Causal-chain navigation + cap-flow visualization + static graph + runtime trace. UX deliverable: three new panel views, navigable via number keys.

**Phase 4**: Notebook substrate + notebook UX (cell editing in panel + save/load + CI mode). UX deliverable: a notebook can be authored in the panel, saved, re-loaded; CI assertion mode works.

**Phase 5**: Hot-toggle integration (via overlay primitive from terminal RFC) + observation-driven test generation. UX deliverable: Ctrl+D opens devtools inline; "generate test from session" works.

**Phase 6**: Rewriteable history + branching time-travel + replay-with-edit diff overlay. UX deliverable: forks visible in the timeline; alternate-run renders side-by-side.

**Phase 7**: Sidecar binary + IPC publish. UX deliverable: separate `fresco-devtools-sidecar` binary connects to a running app and renders its devtools.

**Phase 8**: Verification view + integration with research RFCs as they land. UX deliverable: verification panel showing each research RFC's results inline.

## Open questions

### Q1: Notebook portability across fresco versions

A notebook saved against fresco 0.x.y references signals + types that may not exist in 0.x.z. How does the notebook engine handle missing references — fail loudly? Auto-skip the cell? Migrate?

Lean: fail loudly with a clear error pointing at the missing reference. Notebooks are version-pinned via the schemaVersion + metadata fields.

### Q2: How does the panel handle very large journals?

The journal could have millions of events. The panel views (causal-chain, dep graph, timeline) need to remain responsive. Pragmatic options:
- Auto-snapshot every N events; load only the last N events into view
- Pagination + lazy loading
- Index structures for fast filtering

Lean: implementation-deferred. Build naive; optimize when scale hits.

### Q3: Authorship for the verification view

Each research RFC's static analysis needs to expose its results in a consistent format. Open question: who authors the protocol that the verification panel queries? Each RFC defines its own protocol with the panel coordinating, or a central `intonaco/verification` module that each research direction extends?

Lean: central `intonaco/verification` module with extension hooks. Each research direction adds an entry to a `verificationCheckers: seq[VerificationChecker]` registry at compile time.

### Q4: Hot-toggle when devtools is itself the host app

What happens if the devtools panel itself is opened inside a devtools panel? Recursion: devtools-inside-devtools. Should we forbid, support, or punt?

Lean: forbid (clear error). The use case is contrived and the implementation complexity isn't worth it.

### Q5: Mouse interaction

The interaction models above assume keyboard. Mouse (from the terminal RFC) makes some features more usable (drag the timeline cursor, click to fork, click to expand chain). Mouse is essential for productivity-grade devtools UX.

Lean: design keyboard-first (works on all terminals); enhance with mouse where MouseCap is available.

## Why this is genuinely novel

The integration is the novelty. Each individual feature exists somewhere:
- Time-travel exists (Elm Debugger)
- Causal chains exist (some distributed tracing tools)
- Dep graphs exist (some reactive libraries)
- Notebooks exist (Jupyter)
- Predicate breakpoints exist (Chrome DevTools)
- Static analysis surfacing exists (TypeScript LSP, etc.)

What no library has: **all of them in one substrate, type-checked by a unified capability system, with the journal as the universal source of truth, with the static dep graph as the dataflow substrate, with replay-with-edit as a first-class operation.**

The novelty isn't in any single feature. It's in the substrate-derived integration that makes all features mutually reinforcing. Predicates run on queries over the journal that displays the dep graph that the cap-flow view also reads from. One substrate, ten features, no impedance mismatch between them.

That's the differentiating claim: not "a feature-rich debugger" but "a coherent substrate-derived debugging environment where the features compose because they share the underlying machinery."

## Decision log

(Empty initially.)
