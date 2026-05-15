# fresco — Design

> Source of truth for architecture and locked decisions. Issues reference section anchors here.

## Vision

A terminal-UI **kernel** for Nim. The bottom three tiers (T1-T3) provide pure infrastructure — raw-mode TTY, async keystreams, region-based smart rendering, layout. The top tier (T4) provides the **only user-facing API**: a reactive component system designed for long-running, causally-linked, observable processes — the shape an AI coding agent UI actually needs.

What it explicitly is NOT:
- A retained-mode widget grab-bag (no imperative widgets surface to callers; T4 is the surface)
- A virtual DOM or React reconciler (signals + compile-time dataflow, no VDOM)
- A flexbox layout engine (caller composes via `vstack`/`hstack` DSL; explicit, predictable)
- A monolithic event loop (chronos provides one; fresco hooks in)

The wedge is **kernel-plus-one-API**: solve the hard parts (raw-mode TTY, render-without-clobber, async input, reactive scheduling, journaled state) once and well; expose them through a single, opinionated, novel reactive surface. This is what makes it useful for [amoxtli](https://github.com/coreyleavitt/amoxtli) and for any other Nim CLI that needs a serious interactive surface for long-running processes.

## Identity

- **Language**: Nim 2.x
- **Async**: chronos (matches amoxtli; no std/asyncdispatch)
- **Rendering**: ANSI escape sequences (no curses dependency, no termcap parsing)
- **Layout**: region-based (caller specifies row/col bounds; fresco renders within them)
- **License**: Apache 2.0
- **Distribution**: Nimble package; sibling-library to amoxtli

---

## Locked decisions

### Infrastructure

| # | Topic | Decision |
|---|---|---|
| L1 | Language + async | Nim 2.x + chronos. ARC/ORC, no std/asyncdispatch mixing, taskpools for CPU-bound work. |
| L2 | Kernel-plus-one-API | T1-T3 are pure infrastructure (no user surface). T4 is the only user-facing API. There is no parallel imperative-widget surface. |
| L3 | Single input source | Raw-mode `STDIN_FILENO` → chronos AsyncQueue, routed through T4's mailbox. No sync `readLine` calls anywhere. |
| L4 | Region-based rendering | Caller declares regions (row/col, height/width); render layer tracks per-row dirty state and re-renders minimally. No VDOM. |
| L5 | ANSI sequences | Direct emission via stderr (preserves stdout for piping). No curses. ~98% terminal compat with bare ANSI. |
| L6 | Crash safety | Termios saved at session start; restored via `defer` + signal handlers (SIGTERM, SIGINT, SIGSEGV). Worst case the user can `reset` their terminal but our code does its best. |
| L7 | No theme system | Caller passes ANSI sequences directly (or uses the small `style` helpers). Themes are 10 lines of config in the caller, not a fresco concern. |
| L8 | Dev tooling | Docker for all toolchain ops (Nim, nimble, tests). OpenSUSE Tumbleweed base, mirroring amoxtli. `./dev` shell wrapper. |
| L9 | Test strategy | Tier 1: pure unit (event-stream parser, region geometry, ANSI builder, reactive-graph internals). Tier 2: integration with PTY pair. Tier 3: live smoke against a real terminal (manual). For T4: **the journal is the test oracle**. |
| L10 | First user-visible release | v2.0 (T4 reactive foundation). T1-T3 are scaffolding; nothing is shippable to a caller until T4. |

### T4 (reactive component system)

| # | Topic | Decision |
|---|---|---|
| R1 | Reconciliation | Fine-grained signals + effects. **No VDOM.** Bindings are direct dep→region edges. |
| R2 | Component representation | Direct-style **async coroutines** (`task`) — the task *is* its event loop. Cleanup is structural via scope unwind. |
| R3 | Input dispatch | **Selective `receive`** with pattern arms as the single primitive. Macro-compiled exhaustiveness + ambiguity + priority checks. Hotkeys are scope-registered higher-priority receives. |
| R4 | Reactive graph | **Compile-time-derived static dataflow.** Macro walks typed AST, emits dep edges as constant data. Runtime is a topological scheduler. No runtime tracking stack. |
| R5 | Collections | `state seq[T]` compiles to `CollectionSignal[T]` with delta-tracked operations. Bindings consume deltas, not full values. Frame-clock-paced paint coalescing. |
| R6 | Animation | First-class animated signals as piecewise FRP behaviors. `.tween(target, duration, easing)` on numeric / color / string signals. Frame clock idles when nothing animates. |
| R7 | Primitive unification | `task` subsumes components, workflows, and pure effects. Compiler statically classifies by body. |
| R8 | State substrate | **Journaled event log** as single substrate for state writes, spawns, receives, failures, supervisor decisions. State is left-fold projection. Reactive graph is incremental view maintenance over the log. |
| R9 | Causality | Every event has a typed causal parent. Macro records links at spawn/await/emit sites. Causal DAG queryable from UI and tests. |
| R10 | Capabilities | Capability set inferred per task from body primitives. Static enforcement that callers grant what's required via `provide`. |
| R11 | Speculative scopes | `speculative:` block opens an optimistic-write branch with compensating-revert semantics: writes mutate the signal immediately AND notify observers, while a revert is recorded per write. `commit()` clears the reverts and the writes stick; falling out without commit (normal exit or exception) drains the reverts in reverse, restoring prior values and re-notifying. Observers therefore see intermediate states that may never commit — this is optimistic locking, not classical MVCC isolation. Per-type batching: `Signal[T]` uses per-write revert closures (each rollback notification fires individually). `CollectionSignal[T]` uses per-mutation O(1) inverse-delta capture (push↔remove-at-idx, etc.; only `clear`/`set` snapshot) into a per-scope buffer, and on rollback emits ONE batched `dkRollback` delta carrying every inverse plus ONE `ekCollectionRollback` journal event per affected labeled collection. The trade-off keeps the implementation simple and lets effects re-render against speculative state, which matches the UI use case. |
| R12 | Supervision | Dual surface: declarative `supervisor:` blocks (full OTP — `ssOneForOne` / `ssOneForAll` / `ssRestForOne` / dynamic pools, lifecycle types, restart-rate windows) plus inline `spawn` with per-instance modifiers (`retry`, `catch`, `restart`). |
| R13 | Supervision additions | (a) Per-exception-type `onError:` policies (typechecked against task's exception set); (b) every supervisor decision in the journal; (c) state-restoration policy per child (`replayJournal` / `replayJournalToCheckpoint` / `resetClean`). |
| R14 | Context / DI | Unified **`provide T: v`** / **`use T`** subsumes both capabilities (markers) and services (values). Compile-time discharge along static supervisor paths; runtime fallback for dynamic spawns. Implicit region passing is a special case. |
| R15 | Testing oracle | The **journal is the test oracle**. Tests are tasks; assertions are over event sequences. No snapshot-rendering hacks. |

---

## Architecture

### Tier 1: Terminal foundation

```
src/fresco/
├── terminal/
│   ├── termios.nim     # save/restore + cbreak/raw mode + signal-safe restore (incl. signal hooks)
│   └── ansi.nim        # cursor positioning, line clear, color, styles
├── input.nim           # raw stdin → chronos AsyncQueue[KeyEvent]
└── events.nim          # KeyEvent type + decode (escape sequences → semantic keys)
```

Pure infrastructure. No user-facing API. Re-exported only as primitives for T2-T4. (Signal-handler helpers live alongside termios save/restore — there's no separate `signals.nim`.)

**Allowed dependency exceptions:** `input.nim` (T1) and `hotkey.nim` (T4 but tier-mixed) import:

- `chronos/contextvars` — the continuation-local storage primitive. Provided by chronos (in our fork; upstream PR pending — see `docs/rfc-chronos-contextvars.md`). Any async-suspending code that reads `currentScope` / `currentSpeculative` / `parallelCollector` needs context preservation across `await`, which the dispatcher now handles automatically. There was previously a fresco-side `cls.nim` substrate doing this with macro rewriting; it has been deleted in favor of the chronos primitive.
- `fresco/journal/{events,log}` — journal attribution for input events. Journals are layer-0 audit infrastructure; restricting them to T4 would mean T1 code can't record its own events.

These are the only cross-tier deps; any new ones need DESIGN.md approval.

### Tier 2: Region + render

```
src/fresco/
├── screen.nim          # Screen + Region: geometry, bounds checking, SIGWINCH plumbing
└── render.nim          # Smart line-update: diff intended vs current, emit minimal ANSI
```

Pure infrastructure. T4 sits directly on `Region` and `Screen`. No imperative widget surface ships here. (`Region` is co-located with `Screen` in `screen.nim` rather than in a separate file.)

### Tier 3: Layout

```
src/fresco/
└── layout.nim          # vstack / hstack: stack regions with weights / fixed sizes
```

Pure infrastructure. T4's `vstack:` / `hstack:` DSL blocks compile down to these primitives.

### Tier 4: Reactive component system — *the user-facing API*

```
src/fresco/
├── reactive/
│   ├── scope.nim           # reactive scopes, owner graph, cleanup chains
│   ├── signal.nim          # Signal[T], Computation, signals: macro, := operator, createEffect/Computed
│   ├── binding.nim         # bindRow / bindRows / region: macro
│   ├── context.nim         # provide T: v / use T (DI + capability values)
│   ├── speculative.nim     # optimistic-revert speculative scopes (signal.nim depends on this for revert hooks)
│   ├── animation.nim       # Easing + tween + frame clock
│   ├── collection.nim      # CollectionSignal[T] + Delta[T]
│   ├── static_graph.nim    # `tracked:` typed macro — compile-time dep extraction
│   └── capabilities.nim    # capability markers + `requires` macro
├── task/
│   ├── types.nim           # Mount, MountCollector, parallelCollector — pure data, no async (layer-0 split so low-level modules can reach the types without dragging in lifecycle machinery)
│   ├── core.nim            # task primitive, spawn / spawnRetry / spawnCatch (re-exports types)
│   ├── receive.nim         # selective receive runtime — pattern arms + after timeout
│   ├── parallel.nim        # parallel: block — structured-concurrency group await
│   ├── mount.nim           # mountWhen / mount(cond) — reactive conditional spawn
│   ├── hotkey.nim          # scope-bound input filter
│   └── supervisor.nim      # OTP-flavored supervisor (ssOneForOne / ssOneForAll / ssRestForOne strategies)
├── journal/
│   ├── events.nim          # Event variant + EventId / TaskId distinct types
│   ├── log.nim             # in-memory log + projection (lastWritesByLabel / stateAt / stateAtTime)
│   └── persist.nim         # on-disk JSONL + schema versioning
└── fresco.nim              # public API entry: re-exports the T4 surface
```

This is the only surface a caller imports. T1-T3 modules are reachable but unstable — their public APIs may change between v2.x releases as T4's needs evolve.

Notes on collapsed modules vs the original sketch:
- `terminal/signals.nim` → folded into `terminal/termios.nim` (signal hooks share the snapshot stack with termios save/restore).
- `screen.nim` + `region.nim` → merged: `Region` is a small type and lives next to `Screen` for one-file geometry handling.
- `reactive/graph.nim`, `frame.nim`, `deltas.nim` → became `static_graph.nim`, `animation.nim`, `collection.nim` respectively, with clearer concrete-feature names.
- `journal/time.nim` → bitemporal projection lives directly in `journal/log.nim`.
- `context/provide.nim` → `reactive/context.nim`.
- `macros/*` → each DSL macro is co-located with the runtime module it expands to (`receive` macro in `task/receive.nim`, `region` macro in `reactive/binding.nim`, `supervisor` macro in `task/supervisor.nim`, etc.). No separate macros directory.
- `task/types.nim` → layer-0 split holding `Mount`, `MountCollector`, and `parallelCollector` — pure data, no async machinery. Exists so low-level modules can reach these types without dragging in `task/core.nim`'s lifecycle code. `core.nim` re-exports `types` so existing imports of `task/core` see the same surface.
- `cls.nim` → **removed**. fresco previously carried a continuation-local storage substrate (`{.task.}` pragma + `taskAwait` helper + `TaskContext`) implementing CLS via macro-rewriting around chronos's `await`. v3 replaced this with chronos's native `contextVar` primitive — three threadvars (`currentScope`, `currentSpeculative`, `parallelCollector`) became `contextVar` declarations in their respective modules. The substrate, pragma-order rule, and ~150 lines of macro infrastructure all collapsed into ~3 lines per declaration.

---

## v2.x staging

Five tiers, each independently shippable. Total ~9 weeks of focused work; ~4200 LoC runtime + ~1100 LoC macros + ~2000 LoC tests + ~400 LoC devtools.

### v2.0 — Reactive foundation (~2 weeks)

Minimum coherent surface to write amoxtli's UI in the new model.

- `task` primitive, scope, signal/computed/state — **runtime** dep tracking (Solid-style) as a stepping stone
- `receive:` blocks with macro-compiled pattern matching + exhaustiveness
- `region:` / `row:` / `rows A..B:` bindings — runtime tracking
- `hotkey:` at task scope
- `mount when cond:` for dynamic mount/unmount
- `parallel:` for structured concurrency
- `provide T: v` / `use T` — runtime version, no static discharge yet
- `supervisor:` blocks with `ssOneForOne` only; lifecycle types; restart-rate windowing
- `spawn` with `retry` / `catch` modifiers

### v2.1 — Journal substrate (~1 week)

In-memory event log as the single substrate. No user-facing API change; foundation for v2.2.

- Event variant schema
- Spawn / state-write / receive / failure / supervisor-decision events
- Causal IDs on every event; full causal chain queryable
- `journal.query` API for tests + devtools
- Supervisor crashes route through the journal

### v2.2 — Bitemporal + speculative (~1.5 weeks)

Where the novel synthesis starts paying off for users.

- Time-warp: scrub observation-time, reactive graph re-projects from log
- State-restoration policies (`replayJournal` / `replayJournalToCheckpoint` / `resetClean`)
- `speculative:` scope with optimistic-revert branch-and-commit
- In-process crash recovery (task failure → state survives)
- Per-exception-type `onError:` arms in supervisors

### v2.3 — Performance + animation (~2 weeks)

Invisible upgrades on the existing surface — code written against v2.0 just gets faster.

- **Static reactive graph**: macro lifts dep tracking to compile time; ~10x faster paint path
- **Differential collections**: `state seq[T]` → `CollectionSignal[T]` with delta operations
- **Animated signals**: frame clock, piecewise FRP behaviors, `.tween` API
- Remaining OTP strategies: `ssOneForAll`, `ssRestForOne`

### v2.4 — Capabilities, persistence, devtools (~2 weeks)

Production-grade tier.

- **Capability markers** + runtime-checked `requires` annotation using existing `provide`/`use`
- **On-disk journal** (append-only JSONL) in `$XDG_STATE_HOME/<app>/`; cross-process crash recovery
- Topology query API for external monitoring
- **Devtools example** demonstrating the introspection surface

---

## v3 stretch items

v2.x ships every acceptance criterion from the original five tiers. Items genuinely deferred — either because the v2.4 minimum-viable shape doesn't satisfy the headline ambition (compile-time capability discharge), or because the feature naturally wants amoxtli's real usage to drive design decisions (devtools UI, animation breadth) — are tracked as v3 issues:

- Differential `bindRows` over `CollectionSignal[T]` — incremental row updates
- Animation: `Signal[int]` / `Signal[string]` interpolation + `spring` physics
- Dynamic supervisor pools (`simple_one_for_one`)
- Live time-warp: `rewindTo` / `resumeLive` runtime
- Auto state restoration via `orReplayJournal` policy
- On-disk snapshot + tier compaction + schema versioning
- **Compile-time capability inference** — typed macro walking task bodies, auto-emitting `requires`, discharging against static supervisor topology
- **Reactive devtools panel** built using fresco itself

Not tier-bundled — each lands when there's reason to pull it.

---

## Out of scope

- Windows console (POSIX TTYs only in v0-v2; Windows is post-v2.4 if anyone asks)
- Mouse input (deferred)
- Image rendering (sixel / kitty graphics — separate library)
- Notifications / bells
- Localization beyond UTF-8 width-aware rendering
- Multi-cursor / CRDT state (not amoxtli's need)
- Session types for component event protocols (too heavy ergonomically)
- Hot code reload (Erlang-style — deferred to post-v2.4)

## Open questions

- Exact event-log schema (variant types + field layouts) — resolve during v2.1 implementation.
- Easing-function set + frame-clock FPS configurability — v2.3 detail.
- Devtools panel UI specifics — v2.4 detail.
- On-disk journal binary format + compaction policy — v2.4 detail.
- Macro keyword syntax exact wording (e.g. `mount when` vs `show when`, `:=` vs `<-`) — taste calls during v2.0 implementation.
- Layout DSL extensions beyond vstack/hstack (`overlay`, `centered`, `grid`) — add as need surfaces.
