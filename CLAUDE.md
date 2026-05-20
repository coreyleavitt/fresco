# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This project follows the [AGENTS.md](AGENTS.md) convention — read it for conventions, coding standards, and what not to do. For the locked architecture and tier breakdown, read [DESIGN.md](DESIGN.md). Both are short and authoritative; prefer them over guessing.

## Big picture

`fresco` is the **terminal frontend** of a three-package reactive system for Nim:

```
fresco              — terminal frontend (this repo; terminal-exclusively)
  ↓ depends on
intonaco            — pure reactive substrate (signals/scopes/supervision/journal/caps)
  ↑ depends on
sinopia             — trace frontend; substrate validator + observability tool
```

The three names map to three layers of Renaissance fresco-making (*intonaco* plaster, *sinopia* underdrawing, *fresco* painting). intonaco and sinopia are sibling repos; the mechanical split is Phase 3 of `docs/rfc-intonaco-fresco-split.md`. **Today the single `fresco` repo still contains both substrate and terminal code**; treat that as a transitional state — substrate work should be authored against the post-split shape (no terminal assumptions; no row/region in substrate primitives), and terminal work should stay terminal-shaped. See `docs/rfc-sinopia.md` for what the second frontend looks like and why it exists.

fresco-the-frontend is async on chronos, ANSI-only (no curses), region-based rendering (no VDOM in v0), **terminal-exclusively** (decided 2026-05-20 — fresco does not chase web/voice/headless frontends; sinopia and any future siblings handle those). Library-only Nimble package; sibling to [amoxtli](https://github.com/coreyleavitt/amoxtli), which is the primary downstream consumer. The whole design is shaped by being a library: no `main`-owning runtime, no stdout writes (stdout belongs to the caller's pipe — UI renders to stderr), no second async runtime.

Work is sliced into tiers, each independently shippable. **T1-T3 are fresco-the-terminal-frontend; T4 is substrate that moves to intonaco at Phase 3 of the split.**

- **T1** — `terminal/{termios,ansi}` (signal hooks live in termios.nim) + `input.nim` + `events.nim`. Raw stdin → `AsyncQueue[KeyEvent]`. Crash-safe restore on every exit path including signals. This is the hard part. *Stays in fresco.*
- **T2** — `render/layout.nim` (Layout + Region, geometry, bounds, SIGWINCH) + `render/sink/*` (Sink concept, TerminalSink, MemorySink) + `render.nim` (smart line-update diff). The v0 release target. *Stays in fresco — row-based rendering is terminal-domain.*
- **T3** — `layout.nim` (vstack/hstack) and supporting widget primitives. *Stays in fresco.*
- **T4** — reactive task system: `reactive/` (signals, scope, bindings, speculative optimistic-revert, animation, collection, static graph, context, capabilities) + `task/` (core, receive, parallel, mount, hotkey, supervisor) + `journal/` (events, log, persist). Continuation-local storage is provided by chronos's `contextVar` primitive (added in our chronos fork — see `docs/rfc-chronos-contextvars.md`) — no fresco-side substrate. ***Moves to intonaco at Phase 3.*** Frontend-specific glue that depends on `createEffect` (e.g. `bindRow`, `bindCollection`) stays in fresco because the row-based render model is terminal-domain; intonaco only ships `createEffect` and other frontend-agnostic primitives.

Issues are tracked on GitHub under four milestones — three in fresco (`reactive observability`, `intonaco/fresco split`, `modern terminal interaction`) and one in intonaco (`compile-time research substrate`).

## Non-negotiables

These are the failure modes the design exists to prevent — violating any of them defeats the point of the library:

- **Crash-safe termios restore.** Any code that mutates terminal state must restore on every exit path (normal return, exception, SIGTERM/INT/SEGV). The worst defect class is "left the user's terminal in raw mode." Use `defer` + the signal hooks in `src/fresco/terminal/termios.nim` (`installSignalHandlers` / `uninstallSignalHandlers`).
- **Context across await.** `currentScope`, `currentSpeculative`, and `parallelCollector` are declared via chronos's `contextVar` primitive (in our chronos fork; upstream PR pending). The chronos dispatcher captures the current context at every `addCallback`/`callSoon`/`setTimer` and restores it before firing — bindings survive every `await` automatically. Plain `{.async.}` is enough; no special pragma needed. For callback-style code (effect bodies, input filters) that fires from the dispatcher with whatever context happens to be current, snapshot `currentContext()` at registration and wrap the callback body in `withContext(ctx):` to restore.
- **No stdout writes from library code.** stdout is reserved for the caller's piped output. Render to stderr.
- **One async runtime: chronos.** No `std/asyncdispatch` anywhere. Never `raise` across an async boundary without converting.
- **No curses, no termcap.** Pure ANSI emission. We accept the ~98% terminal-compat tradeoff.
- **No VDOM/reconciler in v0.** Caller owns state; fresco owns the surface.
- **Single chronos dispatcher per process.** chronos's `contextVar` storage, lazy `typeMarker` init, animation frame clock, and POSIX signal handler stack all assume one dispatcher thread. Multi-thread embedders are unsupported: POSIX signals may be delivered to a thread that never called `installSignalHandlers` (terminal stays raw on SIGINT), `typeMarker[T]` first-touch is racy, and tweens issued from non-dispatcher threads silently don't tick. Multi-dispatcher support is a v3 design item; for now, run fresco in the main thread only.
- **Compile-time-first design.** When the same property can be enforced at compile time or at runtime, the substrate enforces it at compile time. Cap concept satisfaction over runtime cap checks; `tracked:` static dependency extraction over runtime tracing; supervisor concept discharge over runtime registration. This is what distinguishes intonaco from runtime-tracking reactive libraries (signals.nim, Sigils). New primitives are evaluated against this rule: *could this be compile-time?* See `docs/rfc-intonaco-fresco-split.md` §"Thesis 1: Compile-time-first."
- **Research drives engineering.** Every substrate-level RFC ships three deliverables: a theoretical contribution (what property is being statically verified, the underlying type-theory / dataflow analysis / effect calculus), engineering primitives (the user-facing API consumers see), and a research artifact (blog post / paper / talk that articulates the contribution). The codebase serves both audiences from the same source. See `docs/rfc-intonaco-fresco-split.md` §"Thesis 2."
- **fresco is terminal-exclusively.** Non-terminal frontends live in sibling packages (sinopia for trace; hypothetical future fresco-web). The substrate (intonaco) is frontend-agnostic; fresco is not. Do not add abstractions in fresco that try to accommodate web/voice/headless rendering. If a feature needs that generality, it belongs in intonaco or in a sibling frontend, not in fresco.

## Dev workflow

All toolchain ops run in Docker (openSUSE Tumbleweed base, mirrors amoxtli). Build the image once, then use the wrapper:

```
./dev image          # (re)build dev image — run once or after Dockerfile changes
./dev check          # nim check — fast type/syntax pass
./dev test           # nimble test — tiers 1 + 2
./dev build          # compile package + examples
./dev shell          # interactive shell inside the container
./dev clean          # remove nimcache + bin
```

Tests are listed individually in `fresco.nimble`'s `task test` block as they land — add new test files there. Tier-3 "live smoke" tests are manual examples run in a real terminal pre-release (not yet built).

## Commit conventions

Conventional commits (`feat:`, `fix:`, `refactor:`, `docs:`, `infra:`, `chore:`). Pre-1.0: commit direct to main, no PRs. No `Co-Authored-By` trailers, no "Generated with…" footers.
