# RFC: intonaco / fresco — substrate split + identity restoration

**Status**: Draft
**Author**: Corey Leavitt
**Supersedes**: the original CLAUDE.md / DESIGN.md framing of "fresco is a terminal-UI kernel"
**Companion to**: `docs/rfc-reactive-observability.md`, `docs/rfc-terminal-interaction.md` (next), `docs/roadmap-compile-time-research.md` (next)

## Why this RFC exists

The library currently shipped as `fresco` started life with the framing "Nim 2.x terminal-UI kernel: async on chronos, ANSI-only, region-based rendering, library-only." That framing is now inaccurate. Roughly 60% of the codebase by line count, and arguably 90% by architectural ambition, is a reactive runtime substrate — signals, scopes, chronos contextvars, OTP-style supervision, journal-as-source-of-truth observability, concept-based capability discharge, multi-source receive, speculative scope, static dependency extraction. The terminal rendering is one consumer of that substrate, not its center of mass.

Three problems follow from the identity drift:

1. **Misframing harms adoption.** Someone arriving at the repo expecting a TUI library sees the cap concept system, the supervisor strategies, the journal causal-chain machinery, and the static dependency macros, and bounces. Someone arriving looking for a reactive Nim library sees "Terminal-UI kernel" in the README and never opens the source.

2. **Architectural pressure points the wrong way.** Every cycle of substrate work feels like "adding to fresco" instead of "extending what's already there." The mental model puts terminal-rendering at the center; substrate work then has to justify itself as something this terminal-UI library happens to have, rather than as what the library actually is.

3. **The substrate genuinely benefits from being its own package.** Multiple frontend audiences (terminal, headless for testing, web for remote tools, bot frontends for chat platforms) can plausibly target the same substrate. Bundling them into a monolithic `fresco` import freezes the architecture into "this is a TUI library with reactive bones" rather than "this is a reactive substrate with multiple frontends."

This RFC restores the substrate to its own identity and splits the package boundary to match.

## The names

After examining the namespace collisions of obvious candidates (`flux`, `reactor`, `nucleus`, `signal`) and considering options, the chosen pair is:

- **`intonaco`** — the reactive substrate. From the Italian word for the smooth top plaster layer of a Renaissance fresco — *the layer onto which paint is applied.* It is the surface that receives and supports the painted image; the substrate beneath what's visible. Metaphorically: intonaco is what fresco is painted onto.
- **`fresco`** — the terminal frontend. Keeps the existing name. A fresco is a mural painted on plaster; the metaphor remains apt for "the painted visible surface rendered to the terminal." `fresco` depends on `intonaco`.

The naming tells the architecture: intonaco is the reactive substrate; fresco is the terminal painting laid atop it. Future frontends (`fresco-web`, `fresco-headless`, `fresco-bot`, etc.) all target intonaco, varying only in what surface the paint lands on.

### Why intonaco specifically

- **Distinctive in the software ecosystem.** Searching for "intonaco" returns conservation/art results, not other software. Anyone Googling the package name finds the project.
- **Thematic pair with fresco.** The metaphor is literal: in a real fresco, the intonaco is what the paint goes onto. The architectural relationship between the substrate and the frontend matches the physical relationship between the two layers.
- **Italian, short-ish, single-word.** Six letters, four syllables (in-toh-NAH-koh). Less familiar to English speakers than `flux` or `reactor`, but the unfamiliarity is the point — the name is unique to this project.
- **Compatible with future frontends.** `fresco-web` reads as "another painting medium over the intonaco." The naming generalizes.

## The identity restatement

The project's central design ethos, made explicit:

> **intonaco is a compile-time-first reactive systems library for Nim.** It combines OTP-style supervision, a journal-as-source-of-truth observability substrate, concept-based capability discharge, and reactive primitives over a chronos contextvar substrate. Wherever a property can be verified at compile time rather than checked at runtime, the substrate prefers compile-time enforcement. The substrate ships frontend-agnostic; `fresco` is the terminal frontend; other frontends (headless, web, bot, sidecar) target the same substrate.

Two non-negotiable theses that follow:

### Thesis 1: Compile-time-first

When the same property can be enforced either at compile time or at runtime, the substrate enforces it at compile time. The cap concept system (compile-time concept satisfaction rather than runtime cap checks), the `tracked:` macro (compile-time dependency extraction rather than runtime tracing), the supervisor concept discharge, the `{.needs.}`/`{.inferCaps.}` pragmas — these are not optional flourishes. They are the consistent expression of an underlying design rule. Future RFCs evaluate proposed primitives against this rule: *could this be compile-time?*

This is what differentiates intonaco from signals.nim (runtime fine-grained reactivity), Sigils (runtime signal/slot dispatch), and the broader runtime-tracking norm in reactive libraries. Compile-time work costs more LoC, longer compile times, more macro complexity — and pays back in correctness, performance, and verifiable safety properties that runtime systems fundamentally cannot achieve.

### Thesis 2: Research drives engineering

Every substrate-level RFC ships three deliverables:

1. **A theoretical contribution** — what property is being statically verified, what's the underlying type-theory / dataflow analysis / effect calculus.
2. **Engineering primitives** — the user-facing API that consumers see, the practical artifacts that fall out of the theoretical work.
3. **A research artifact** — blog post, paper, or talk that articulates the theoretical contribution to its audience.

The engineering audience consumes the primitives without needing to read the theory. The research audience reads the theory and sees the primitives as concrete instantiations. The same codebase serves both.

This positioning is precedented: LLVM started as compiler research that became industrial infrastructure; Rust solved real type-theory problems that produced a practical language; QUIC was research that became HTTP/3. In each case, the research is what made the engineering good enough to adopt; the engineering is what made the research consumable. intonaco aims for the same shape.

## Where the line lives

The split between `intonaco` (substrate) and `fresco` (terminal frontend) is drawn at the natural seam exposed by the codebase. The line is not arbitrary; it's where dependencies on `Region`, `Screen`, `Terminal`, and ANSI emission either appear or disappear.

### intonaco contains

- `reactive/` — signals, computations, scopes (with `currentScope` chronos contextVar), context (provide/use), capabilities (cap T + concept discharge + `currentSup`), speculative scope, animation math (pure tween/easing — no rendering), collection signals with delta observers, static dependency extraction (`tracked:` macro)
- `reactive/binding.nim` — but **rewritten** to depend on a `RenderTarget` interface (see below) rather than on `Region` directly. The terminal-specific `bindRow`/`bindRows`/`bindCollection` macros become parameterized over targets.
- `task/` — Mount, spawn primitives, parallel collectors, multi-source receive, mailbox, supervisor (lcPermanent/lcTransient/lcTemporary, ssOneForOne/ssOneForAll/ssRestForOne, error policies, onRestart handlers, adopted task groups)
- `journal/` — events, append-only log, JSONL persistence, rewindTo/resumeLive, snapshots, causal-chain ancestors
- The capability concept substrate: `cap T` macro, `{.needs.}` pragma, `{.inferCaps.}` pragma, `supervisor:` macro (the unified one from #72), `currentSup()` accessor

### fresco contains

- `terminal/` — termios (cbreak + crash-safe restore), ANSI emission helpers, signal hooks
- `screen.nim` — Screen, Region, smart line-update diff
- `render.nim` — the diff renderer (driver for the terminal RenderTarget)
- `input.nim` — InputStream, cancel-safe nextKey
- `events.nim` — KeyEvent, modifiers
- `layout.nim` — vstack/hstack (terminal-specific, operates on Regions)
- `hotkey/` — keyboard pattern matching (depends on KeyEvent which is terminal-specific)
- A `TerminalRenderTarget` implementation that bridges `intonaco`'s binding system to fresco's Screen/Region
- Terminal-specific cap concepts (TruecolorCap, SixelCap, KittyGraphicsCap, etc. — added by the terminal RFC) — these are intonaco-style caps but declared in fresco because they're terminal-domain
- `devtools/` — the panel + widgets. Lives in fresco because the panel is a terminal-rendered consumer. The query-substrate primitives (from the observability RFC) live in intonaco; the panel that visualizes them lives in fresco.

### Pieces that aren't immediately obvious

- **`hotkey/` lives in fresco**, not intonaco. The routing-macro itself is a general AST pattern but the `KeyEvent` type is terminal-shaped (modifier sets, key codes). When other frontends arrive (web, bot), they may have their own event vocabularies; hotkey-like routing for those would live in those frontend packages.

- **Animation math lives in intonaco** (it's pure tween / easing functions over `T`), but **animated bindings live in fresco** because they need to drive a terminal-specific rendering schedule. The split is "pure math here, render-driving there."

- **The cap concept primitives live in intonaco** (`cap T`, `Grants*` concept generation, supervisor discharge), but **terminal-specific cap tokens** (`TruecolorCap`, `SixelCap`) live in fresco. Same substrate, frontend-specific extensions.

- **Devtools panel lives in fresco**, but the **devtools query substrate** (from the observability RFC) lives in intonaco. The split keeps "consuming the journal/topology" in the substrate while "rendering it as a panel" stays in the terminal frontend.

## The `RenderTarget` interface

Today `bindRow`/`bindRows`/`bindCollection` take a `Region`. To split cleanly, the binding system needs to be parameterized over an abstraction that the terminal frontend (and future frontends) implements.

### Sketch

```nim
type
  RenderTarget* = concept t
    ## What every frontend's render surface must support for intonaco's
    ## binding system to drive it. Minimal interface; rich frontends
    ## extend with their own additional capabilities.
    t.setLine(row: int, content: string)
    t.invalidate(rows: Slice[int])
    t.height: int
    t.width: int
```

`fresco.Region` becomes one impl of `RenderTarget`. A future headless driver provides a different impl (capturing rendered lines in-memory for testing/CI). A future web driver provides another (shipping rendered cells over WebSocket). A future file driver provides another (dumping ASCII to a file).

The binding macros (`bindRow`, `bindRows`, `bindCollection`) become generic over `RenderTarget`. Terminal-specific niceties (background color writes, cursor positioning, etc.) layer on top via additional concepts (`ColoredRenderTarget`, `PositionableRenderTarget`).

### Why concept-typed and not interface inheritance

intonaco's existing cap system is concept-based for the architectural reasons documented in the μb rewrite (structural typing, no global registry, compile-time discharge). `RenderTarget` follows the same convention: a structural concept that any type with the right shape satisfies. Frontend implementations don't need to inherit from a common base; they need to expose the right operations.

## Phasing

Three phases. Each independently shippable. The phases are *not* "the split happens in one go" — they're a careful sequence that validates the abstraction before committing to the package boundary.

### Phase 1: `RenderTarget` interface inside the current package

Land `RenderTarget` as a concept. Refactor `binding.nim` to use it. `Region` becomes the existing impl. No package boundary change; the binding macros now operate on `RenderTarget` instead of `Region`, but at runtime the same code runs.

This is mechanical refactoring. The macros change shape, internals stay similar, all existing tests should pass without modification. Estimated 2–3 cycles.

**Acceptance:**
- `RenderTarget` concept declared
- `bindRow`/`bindRows`/`bindCollection` parameterized over `RenderTarget`
- `Region` continues to work as the implementation
- All existing tests pass
- A trivial in-memory `RenderTarget` implementation exists in the test harness (proves the abstraction is real)

### Phase 2: Headless driver as the second consumer

Build a proper headless driver that's first-class, not just a test fixture. Lives initially in `tests/` or `src/fresco/headless/` (still inside the current package, ahead of the actual split).

The headless driver provides:
- `HeadlessRenderTarget` — captures rendered lines in-memory
- A synthetic input source (for driving the headless app in CI)
- A `runHeadless(app, inputScript, expectedOutput)` test harness

This is the second consumer that validates the abstraction. Without it, the `RenderTarget` interface might be subtly terminal-shaped without us realizing.

Estimated 2–3 cycles. Probably worth its own small RFC since the test-harness aspects could be substantial.

**Acceptance:**
- `HeadlessRenderTarget` ships
- A test demonstrates running a fresco app under headless and asserting on output
- The existing devtools panel runs under headless successfully (its render output matches what a terminal session would produce)
- CI test harness uses headless to assert on rendered output of example apps

### Phase 3: Mechanical package split

Once the abstraction is proven by two consumers (terminal + headless), the package split is mechanical:

- Move `reactive/`, `task/`, `journal/`, `cap T`, `{.needs.}`, `{.inferCaps.}`, `supervisor:` macro, observability substrate to `intonaco/`
- Keep `terminal/`, `screen.nim`, `render.nim`, `input.nim`, `events.nim`, `layout.nim`, `hotkey/`, `devtools/panel.nim`, `devtools/widgets.nim`, terminal-cap tokens, `TerminalRenderTarget` in `fresco/`
- `fresco` package depends on `intonaco`
- Update `fresco.nimble` to express the dependency
- Update all imports

The hard part of the split is the abstraction (Phase 1) and the validation (Phase 2). Phase 3 is moving files and updating imports. Estimated 1–2 cycles.

**Acceptance:**
- `intonaco` is a standalone Nimble package, installable independently
- `fresco` is a separate Nimble package that requires `intonaco`
- All existing tests pass on both
- Headless driver lives in `intonaco` (since it's substrate-side); terminal driver lives in `fresco`
- amoxtli (or any consumer) updates its `requires` to depend on both, or `fresco` transitively pulls in `intonaco`

### What does NOT happen during phasing

- **No public API breaks for the surface users see.** A consumer that today imports `fresco` and uses `bindRow`, `signal`, `supervisor:`, etc. continues working. They might need to add `requires "intonaco"` to their nimble after Phase 3, or fresco's nimble might `requires "intonaco"` transitively. Either way the user-facing macros and types don't change.
- **No name changes for existing primitives.** `Signal`, `Computation`, `Supervisor`, `Journal`, `Region`, `Screen`, `KeyEvent`, `bindRow`, `supervisor:`, `cap`, `{.needs.}` — all stay named what they're named.
- **No restructuring of internal logic.** Phase 3 is moves, not rewrites.

## Identity rewrite

Concurrent with this RFC landing: `DESIGN.md` and the top-level `README.md` are rewritten to reflect the restored identity. The current "fresco is a Nim 2.x terminal-UI kernel" framing is replaced with the two-package positioning:

### `DESIGN.md` (substantial rewrite)

- Top-level statement: "intonaco is a compile-time-first reactive systems library; fresco is its terminal frontend."
- Compile-time-first thesis as explicit non-negotiable, alongside the existing non-negotiables (crash-safe termios restore, no stdout writes, single chronos dispatcher, etc.)
- Research-drives-engineering thesis as the second new non-negotiable
- Two-package architecture overview: what's in intonaco, what's in fresco, the `RenderTarget` interface as the seam
- Updated tier breakdown reflecting both packages

### `README.md` (substantial rewrite)

- Two-package elevator pitch
- "Choose your package" section: which to depend on based on what you're building
- Roadmap pointer (to research roadmap + terminal RFC + observability RFC)
- Quick examples of intonaco-only use (e.g., a daemon with no terminal UI), fresco use (a TUI app), and mixed use (the existing devtools-style apps)

### `CLAUDE.md` (smaller rewrite)

- Updated identity statement matching DESIGN.md
- Updated non-negotiables list (adds compile-time-first and research-drives-engineering)
- Tier breakdown updated for two packages
- Pointer to the new docs

## Migration plan for in-flight RFCs

Three in-flight RFCs need to be reconciled with the split:

### Reactive observability RFC (`docs/rfc-reactive-observability.md`)

The substrate layer (`fresco/obs`) becomes `intonaco/obs`. The panel renderer (the existing `runDevtoolsPanel` + Phase 4 notebook UI) stays in `fresco/devtools/`. The sidecar IPC (Phase 6) lives in intonaco because it's substrate IPC; the *terminal* sidecar UI binary lives in fresco.

This is a renaming + relocation, not a re-design. The architecture in the RFC stays correct.

### Terminal interaction RFC (`docs/rfc-terminal-interaction.md`, to be written next)

Entirely fresco-side, with caveats:
- Capability detection produces `intonaco`-style cap tokens (declared in fresco/term/caps)
- The `supervisor:` macro and cap discharge are intonaco primitives that fresco's render code consumes
- The split doesn't change the terminal RFC's design, but the RFC will be written with the post-split package structure in mind

### Compile-time research roadmap (`docs/roadmap-compile-time-research.md`, to be written next)

Entirely intonaco-side. The six research directions (information-flow analysis, effect/intent classification, linear caps, temporal invariants, UI completeness proofs, reactive ABI) all live in intonaco. The roadmap document is written for the post-split structure.

UI completeness proofs are a slight exception — they touch both packages (the substrate verifies the proofs; the terminal renderer demonstrates them). The headline research RFC will treat them as intonaco substrate work with fresco-side validation.

## Open questions

### Q1: Should the headless driver live in `intonaco` or `fresco-headless`?

Two options:
- **Inside `intonaco`**: makes sense because intonaco is "the substrate that frontends target," and headless is the most natural substrate-validation frontend. The substrate ships with a default frontend (headless) usable for testing without ever pulling in fresco.
- **As its own package `fresco-headless`**: more conservative split; intonaco stays "pure substrate" with zero frontend code.

Lean: headless lives in intonaco. It's testing infrastructure that the substrate authors need, not a separate adoption target. Anyone using intonaco wants headless available for tests.

### Q2: How does amoxtli (or any consumer) install both packages?

Options:
- **Explicit two `requires` lines**: `requires "intonaco"; requires "fresco"`. Honest, explicit, slightly more boilerplate.
- **Transitive via fresco**: `requires "fresco"` and fresco's nimble file pulls in intonaco. Less boilerplate, but the dependency relationship is hidden.

Lean: transitive via fresco for terminal consumers, explicit for non-terminal consumers. Most TUI app authors only think about fresco; they get intonaco transitively. A web-frontend or bot-frontend author depends on intonaco directly + their chosen frontend.

### Q3: Versioning between the two packages

intonaco and fresco will have their own version numbers. Compatibility matrix:
- fresco x.y.z requires intonaco a.b.c (specified in fresco's nimble)
- Major version bumps in intonaco may break fresco; fresco's nimble pins compatible versions
- Pre-1.0 (both packages), versions can move fast independently
- Post-1.0, intonaco's stability becomes a precondition for fresco's stability

### Q4: What's the 1.0 criterion?

Mentioned in earlier discussions. Now formalized as two-track:

**intonaco 1.0:**
- Cap system stable (no more rewrites)
- Observability substrate landed (RFC complete, phases 1-3 shipped)
- At least one major compile-time-research RFC landed (probably information-flow as the highest-leverage first)
- Reactive substrate API frozen (no more renames of core types)
- Documentation site live

**fresco 1.0:**
- Driver abstraction stable
- Terminal capability detection + cap unification landed
- Universal polish primitives (pills, animation, iconography, hyperlinks, OSC) shipped
- Image protocols stable (at least sixel + kitty)
- Layout system upgrade landed (more than vstack/hstack)
- Documentation site live

Both 1.0s are gated on real validation by at least one external consumer.

## Why now

The split is being declared now (mid-pre-1.0) rather than later (closer to 1.0) for four reasons:

1. **Substrate work is mid-flight.** The observability RFC, the terminal-cap unification, the compile-time research roadmap — all are substrate-shaped work that should be authored against the right package structure. Writing them as "fresco features" would lock in the wrong mental model.

2. **No production users yet.** This is the cheapest moment to split. Every consumer that adopts fresco-the-monolith creates an import-statement migration cost. Right now that cost is roughly zero.

3. **The identity drift is already causing decision-friction.** Every "is this a fresco feature or a substrate feature?" question that's come up in recent cycles has had to be answered ad-hoc. Splitting the packages turns that ad-hoc judgment into a structural rule.

4. **Compile-time-first ethos needs an identity hook to declare itself.** Saying "fresco is a TUI library that happens to do compile-time-first work" undersells it. Saying "intonaco is the compile-time-first reactive substrate, fresco is the terminal frontend" puts the ethos at the architectural center.

## Decision log

(Empty initially. Decisions made during implementation get appended.)
