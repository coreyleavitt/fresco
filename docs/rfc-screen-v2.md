# RFC: Screen v2 — reactive surface, auto-paint, sink-polymorphic

**Status**: Draft
**Author**: Corey Leavitt
**Companion to**: `docs/rfc-intonaco-fresco-split.md`, `docs/rfc-terminal-interaction.md`, `docs/rfc-reactive-observability.md`
**Targets**: fresco (terminal frontend; post-Phase-2 split)

## Why this RFC exists

After the intonaco/fresco split landed Layout + Sink + TerminalSink + MemorySink, `Screen` was kept as a thin `(Layout, TerminalSink, SIGWINCH)` wrapper. That bundling is the right idea — every terminal app needs the triplet, and forcing each caller to build it manually is poor ergonomics — but the *shape* of the current Screen is v0 and shows it:

1. **`screen.height: int` is a mutable field** in a codebase where every other observable is a `Signal[T]`. Resize is propagated by a process-global `resizePending: bool` flag plus a `resize(s)` mutator that callers poll for via `isResizePending()`. Bindings cannot react to terminal-size changes directly; the app loop has to notice and re-flow regions itself.

2. **`screen.paint()` is called manually after every event** in every example and in amoxtli. In a reactive system with a frame clock already in flight (intonaco's animation infrastructure), paint should be a dirty-mark side-effect, not an explicit call. The manual paint pattern is an artifact of v0 when there was no frame clock to integrate with.

3. **`screen.sink: TerminalSink` is monomorphic**. Sink was introduced as a concept exactly so a single rendering pipeline could target multiple output backends; Screen baking in `TerminalSink` defeats that for the most common entry-point type. Headless tests want `MemorySink` behind the same ergonomics. The devtools panel taking `Screen` therefore can't run under headless testing without either bypassing Screen or refactoring the panel separately.

4. **`screen.caps: TerminalCaps`** does not exist yet but is required by the terminal-interaction RFC's capability-detection work. The natural place for "what does this terminal support" to live is on the terminal-frontend entry point. Whatever shape capabilities take, they should be a Signal (capabilities can change — alt-screen toggling, terminal multiplexer reattach, OSC-queried at startup completes after first paint).

These warts are not v0 bugs; they're consequences of Screen predating the reactive surface, the frame clock, the Sink concept, and the terminal-interaction RFC. The fix is a shape rewrite, not a deletion.

## The new shape

```nim
type
  Screen*[S: Sink] = ref object
    layout*: Layout
    sink*: S
    size*: Signal[(int, int)]      # reactive; updated on SIGWINCH or initial query
    caps*: Signal[TerminalCaps]    # reactive; populated by capability detection
    autoPaint*: bool               # default true; set false to opt into manual paint

  TerminalScreen* = Screen[TerminalSink]
  MemoryScreen*   = Screen[MemorySink]

proc newScreen*(): TerminalScreen
  ## Queries TIOCGWINSZ, opens a TerminalSink on STDERR_FILENO,
  ## installs SIGWINCH→AsyncEvent→size signal plumbing, registers
  ## an auto-paint effect against the frame clock. Default
  ## construction for production terminal apps.

proc newScreen*(sink: S, h, w: int): Screen[S]
  ## Explicit-sink constructor for tests and non-default fds.
  ## No SIGWINCH plumbing (caller drives size signal directly).

proc newRegion*(s: Screen, row, col, height, width: int): Region
  ## Same as today.

proc paint*(s: Screen)
  ## Manual paint. Most callers never call this — bindings auto-mark
  ## regions dirty; the frame-clock effect calls paint on the next
  ## tick. Provided for explicit-flush use cases (tests, post-exit
  ## final render).
```

The four warts each have a direct mechanism in the new shape:

1. **`size: Signal[(int, int)]`** — SIGWINCH handler writes to an `AsyncEvent`; a chronos task awaits the event and calls `size.set((h, w))`. Bindings reading `screen.size()` re-run via the standard reactive plumbing. `isResizePending` and `resize(s)` are deleted.

2. **`autoPaint: bool = true`** — `newScreen` registers a frame-clock effect that calls `sink.commit(layout)` whenever any region is dirty. Explicit `screen.paint()` calls in app code can all be deleted. Tests that want deterministic paint timing set `autoPaint = false` and call `paint(s)` between phases.

3. **`Screen[S: Sink]` generic** — `TerminalScreen` and `MemoryScreen` aliases give the two main shapes a name. The devtools panel takes `screen: Screen[S]` (or, equivalently, a `screenLike` concept) and runs under both. The same path that powered Screen-as-wrapper for tests now powers genuine sink-polymorphic test infrastructure.

4. **`caps: Signal[TerminalCaps]`** — populated by the capability-detection work from the terminal-interaction RFC. Initially queries on construction; can re-query on terminal-multiplexer detach/reattach. Bindings that depend on capabilities (e.g. "render this widget with truecolor if available, fallback otherwise") re-run automatically when caps change.

## What stays the same

- `newScreen()` is still the one-line production entry point.
- `screen.newRegion(...)`, `screen.layout`, `screen.sink` ergonomics unchanged.
- `Layout`, `Region`, `Sink`, `TerminalSink`, `MemorySink` types are untouched. Only `Screen` is rewritten.
- SIGWINCH is still terminal-frontend infrastructure — it lives in fresco, not intonaco. The new plumbing routes through an AsyncEvent + signal write, but the handler installation is fresco's responsibility.
- Bindings APIs (`bindRow`, `bindCollection`, etc.) don't change. They mark regions dirty; the new auto-paint effect picks that up. Today they require an explicit `screen.paint()` after the event loop tick; tomorrow they don't.

## SIGWINCH → AsyncEvent → Signal plumbing

A POSIX signal handler can't safely mutate Nim seqs or call into the dispatcher. The standard chronos-shaped solution is the self-pipe trick:

```nim
type
  ResizeMonitor = ref object
    event: AsyncEvent
    size: Signal[(int, int)]
    fd: cint

proc winchHandler(sig: cint) {.noconv.} =
  # Signal-safe: just fire the AsyncEvent. The dispatcher will
  # wake any task awaiting it.
  monitorRef.event.fire()

proc resizeLoop(m: ResizeMonitor) {.async.} =
  while true:
    await m.event.wait()
    m.event.clear()
    let (h, w) = queryWinsize(m.fd)
    m.size.set((h, w))
```

The Signal write runs reactive effects (region resize callbacks, layout re-flow); the auto-paint effect ticks on the next frame. End to end: SIGWINCH arrives → handler fires AsyncEvent → resizeLoop wakes → size signal updates → effects re-run → regions re-flow → dirty marks set → frame clock paints. All async-clean, no polling, no global flag.

`AsyncEvent` is chronos's fd-backed event primitive; it's exactly the right abstraction here.

## Frame-clock auto-paint

intonaco's animation module (`reactive/animation.nim`) already runs a frame clock that ticks at a configurable rate (default 60Hz) when there is any active tween. For auto-paint, we need the clock to also tick when there is any *dirty region* — otherwise an app with no animations would never paint.

Two implementation options:

- **Always-running clock when Screen exists.** Simplest. Screen's constructor starts the frame clock; destructor stops it. The clock ticks at the configured rate; the auto-paint effect calls `sink.commit(layout)` if (and only if) any region is dirty. Trade-off: 60 wakeups/sec for an idle app, all of which find nothing to do.
- **Dirty-mark-triggers-clock.** Region's `markDirty` posts to an AsyncEvent; the frame clock advances exactly one tick after the next mark. Trade-off: more complex; risk of missed paints if the event semantics aren't exactly right.

Lean: always-running clock when Screen exists. 60 wakeups/sec is trivial compared to the 1000Hz event loops the dispatcher already runs for idle awaits; the simplicity is worth more than the wakeup savings.

The clock should idle (zero wakeups) when no Screen exists, so non-terminal programs that depend on intonaco transitively don't pay the cost. That's the existing animation-module behavior; the new auto-paint effect just adds another reason for the clock to tick.

## Tests and `autoPaint = false`

Many existing tests rely on synchronous paint semantics: bind, mutate, assert on bytes emitted. Auto-paint breaks this — the paint happens on the *next* frame, not on the current await point. Migration:

```nim
let s = newScreen(newMemorySink(), 5, 20)
s.autoPaint = false                      # opt out
let r = s.newRegion(0, 0, 5, 20)
bindRow r, 0: "hello"
paint(s)                                 # explicit
check s.sink.lastWrite == expectedBytes
```

`autoPaint = false` keeps the tests deterministic. Production apps don't set it; auto-paint is the default for production. Tests that *want* to assert on paint scheduling (e.g. "this widget should paint exactly once per signal write") set `autoPaint = false` and drive paint explicitly.

## Phasing

Phase 1 and Phase 2 are independently shippable; Phase 3 is the deletion sweep.

### Phase 1: Reactive size signal (~2 cycles)

- `Screen` gains `size: Signal[(int, int)]` (mutable field still present, kept in sync).
- SIGWINCH plumbing rewritten to fire an `AsyncEvent`; a resizeLoop task writes the signal.
- `isResizePending()` and `resize(s)` still exist, deprecated, but their bodies become "read the signal" / "no-op."
- A new binding form (or just plain `createEffect` consuming `screen.size`) demonstrates reactive resize handling.
- Tests assert that resize updates the signal.

**Acceptance:**
- An example app that re-flows regions based on `screen.size()` (no `isResizePending` check) ships in `examples/`.
- All existing tests pass; the deprecation warnings on `isResizePending` are introduced.

### Phase 2: Sink-polymorphic Screen (~2 cycles)

- `Screen` becomes `Screen[S: Sink]`. `TerminalScreen = Screen[TerminalSink]` and `MemoryScreen = Screen[MemorySink]` aliases ship.
- `runDevtoolsPanel` becomes generic over Sink (or takes `ScreenLike`).
- A test exercises the devtools panel under MemoryScreen, asserting on the rendered byte output.
- The existing `runHeadless` harness moves to a thin wrapper around `MemoryScreen` + `SyntheticInputStream`.

**Acceptance:**
- Devtools panel runs under MemoryScreen in a CI test, asserting on output.
- amoxtli (if migrated by this point) continues to work with no surface change — `newScreen()` returns `TerminalScreen` and the API is identical to today's.

### Phase 3: Auto-paint via frame clock (~1-2 cycles)

- `Screen` constructor registers the auto-paint effect.
- Manual `screen.paint()` calls are removed from `examples/`.
- Tests that need deterministic paint timing add `autoPaint = false`.
- `caps: Signal[TerminalCaps]` is wired up (depends on capability-detection work from terminal-interaction RFC — may slip if that's not done).

**Acceptance:**
- All examples have no `paint()` call in their event loop.
- Test suite passes with a mix of auto-paint and explicit-paint tests.
- The pattern documented in DESIGN.md as the canonical app shape.

## Migration impact

- **Production callers (amoxtli)**: no API surface change for the common case. `newScreen()` returns a TerminalScreen; the `.newRegion / .paint` methods exist with the same signatures. The `paint()` call becomes optional (auto-paint covers it) but doesn't break if kept. `isResizePending()` is deprecated but doesn't break.
- **Test callers (~80 sites in fresco)**: most need `autoPaint = false` added; otherwise unchanged. The few that exercise `isResizePending` need updating to consume the size signal.
- **Devtools panel**: signature changes from `screen: Screen` to `screen: Screen[S]` (or `ScreenLike` concept). Internal — no external surface impact.

## Open design questions

### Q1: `Screen[S]` generic vs `ScreenLike` concept

Both work for the panel refactor. Generic is more explicit; concept is more flexible (allows third-party `screen-like` types). intonaco's existing pattern is concept-based (`cap T`, `RenderTarget`, `Sink` itself); consistency suggests concept. Lean: `ScreenLike` concept, with `Screen[S]` as the canonical impl and `TerminalScreen` / `MemoryScreen` as aliases.

### Q2: Frame clock cost for non-animation idle apps

60Hz wakeups for an idle terminal app are wasteful. The same wakeup is cheap (~microseconds), but it's user-perceptible if energy-sensitive (laptop battery, embedded contexts). Alternatives:

- Drop the auto-paint tick rate to 10Hz unless an animation is active (animation re-bumps to 60Hz).
- Use the dirty-mark-triggers-clock variant despite the complexity cost.
- Provide a `Screen` constructor option for tick rate.

Lean: 60Hz when any region is dirty *or* any animation is active; idle (0Hz) otherwise. Implementation needs a "dirty global" reactive observation; doable.

### Q3: `caps: Signal[TerminalCaps]` shape

The terminal-interaction RFC defines `TerminalCaps` as a record of detected capabilities (truecolor, sixel, kitty-graphics, OSC52, hyperlinks, etc.). Open question: should each capability be its *own* signal so bindings reading one don't re-run when an unrelated one changes? E.g. `screen.truecolor: Signal[bool]`, `screen.sixel: Signal[bool]`, etc.

Lean: single `caps: Signal[TerminalCaps]` for v2.0; split into per-capability signals if a real workload shows the unnecessary re-runs hurt. Premature granularity is the worse default.

### Q4: Constructor for non-stderr fds

Today `newScreen(fd)` lets a test point Screen at a different fd. The new `newScreen()` no-arg version assumes stderr. Tests can use `newScreen(newTerminalSink(fd), h, w)` for explicit fds; should we also keep a `newScreen(fd)` shortcut? Lean: yes, keep the shortcut.

## Why now

- The Phase 2 deferred items (delete Screen, panel sink-agnostic) surfaced these warts. Rather than do the wrong cleanup (delete Screen) or the half-cleanup (function-callback panel), the right answer is to fix the shape that motivated both.
- The capability-detection work in the terminal-interaction RFC needs a `caps` signal on Screen. Pinning Screen v2's shape now means the cap-detection work has a target to write to.
- The reactive-observability RFC's auto-paint integration point is the frame clock; Screen v2's auto-paint is one of its consumers. Designing them in isolation risks landing two incompatible frame-clock contracts.

## Decision log

(Empty initially. Decisions made during implementation get appended.)
