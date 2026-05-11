# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This project follows the [AGENTS.md](AGENTS.md) convention — read it for conventions, coding standards, and what not to do. For the locked architecture and tier breakdown, read [DESIGN.md](DESIGN.md). Both are short and authoritative; prefer them over guessing.

## Big picture

`fresco` is a Nim 2.x terminal-UI **kernel** (not a framework) — async on chronos, ANSI-only (no curses), region-based rendering (no VDOM in v0). Library-only Nimble package; sibling to [amoxtli](https://github.com/coreyleavitt/amoxtli), which is the primary downstream consumer. The whole design is shaped by being a library: no `main`-owning runtime, no stdout writes (stdout belongs to the caller's pipe — UI renders to stderr), no second async runtime.

Work is sliced into tiers, each independently shippable:

- **T1** — `terminal/{termios,ansi}` (signal hooks live in termios.nim) + `input.nim` + `events.nim`. Raw stdin → `AsyncQueue[KeyEvent]`. Crash-safe restore on every exit path including signals. This is the hard part.
- **T2** — `screen.nim` (Screen + Region, geometry, bounds, SIGWINCH) + `render.nim` (smart line-update diff). The v0 release target: enough to power amoxtli's permission prompt + live status while streaming output above the widget without clobbering it.
- **T3** — `layout.nim` (vstack/hstack) and supporting widget primitives.
- **T4** — reactive task system: `reactive/` (signals, scope, bindings, speculative MVCC, animation, collection, static graph, context, capabilities) + `task/` (core, cls, receive, parallel, mount, hotkey, supervisor) + `journal/` (events, log, persist).

Issues are tracked on GitHub under three milestones (v0/v1/v2) matching T1+T2 / T3 / T4.

## Non-negotiables

These are the failure modes the design exists to prevent — violating any of them defeats the point of the library:

- **Crash-safe termios restore.** Any code that mutates terminal state must restore on every exit path (normal return, exception, SIGTERM/INT/SEGV). The worst defect class is "left the user's terminal in raw mode." Use `defer` + the signal hooks in `src/fresco/terminal/termios.nim` (`installSignalHandlers` / `uninstallSignalHandlers`).
- **Context across await.** `currentScope`, `currentSpeculative`, and `parallelCollector` are thread-locals that chronos doesn't restore on resume. Annotate any async proc that depends on them with `{.task, async.}` — the `task` pragma in `src/fresco/task/cls.nim` rewrites every `await` in the body to inline save/restore. For callback-style code (effect bodies, input filters) that fires from the dispatcher, wrap the body in `withContext(capturedCtx):`.
- **No stdout writes from library code.** stdout is reserved for the caller's piped output. Render to stderr.
- **One async runtime: chronos.** No `std/asyncdispatch` anywhere. Never `raise` across an async boundary without converting.
- **No curses, no termcap.** Pure ANSI emission. We accept the ~98% terminal-compat tradeoff.
- **No VDOM/reconciler in v0.** Caller owns state; fresco owns the surface.

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
