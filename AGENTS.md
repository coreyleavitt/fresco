# AGENTS.md

Conventions for AI coding agents working on this repository (we dogfood `amoxtli` here, so these conventions apply to us too).

## Project at a glance

`fresco` is a Nim terminal-UI kernel — raw-mode input + region rendering + a reactive task system (T4). T1-T3 are pure infrastructure; T4 is the only user-facing API. Built as a sibling library to `amoxtli` (its primary consumer) but designed to be useful to any Nim CLI that needs a serious reactive surface. See [DESIGN.md](DESIGN.md) for the locked architecture.

- Language: **Nim 2.x**. Async via **chronos** (not std/asyncdispatch). GC: ARC/ORC.
- Rendering: ANSI escape sequences (no curses).
- Distribution: Nimble package (`fresco`).
- License: MIT.

## Coding conventions

- **Async**: chronos `{.async.}` for any I/O. Cancellation via `CancellationToken`; respect it.
- **No `echo`** in library code — caller controls output. Tests can echo for diagnostics.
- **Crash safety**: any code that mutates terminal state (termios, cursor, alt-screen) must restore on every exit path including panics. Use `defer` + signal hooks; prefer the signal-hook helpers in `src/fresco/terminal/termios.nim` (`installSignalHandlers` / `uninstallSignalHandlers`).
- **No vendored C**: prefer `{.importc, header.}` over `{.compile.}` for syscalls.
- **State machines**: object variants + exhaustive `case`. Don't reach for tagged Tables unless open extension is genuinely needed.
- **Errors**: results-style for expected failures (`Result[T, E]` or sum types), exceptions for genuinely-exceptional. Never `raise` across an async boundary without converting.
- **Comments**: only when the WHY is non-obvious. No commentary explaining what the code does — naming should do that.
- **No `stdout` writes** from fresco code (unless user opts in via a flag). Use `stderr` for the rendered UI; stdout is reserved for the caller's piped output.

## Test strategy

Three tiers, mirroring amoxtli's approach:

1. **Unit** (`tests/unit/test_*.nim`) — pure functions: ANSI builder, key event decoder, region geometry. Every save.
2. **Integration** (`tests/integration/test_*.nim`) — drive real termios + a PTY pair. Verify input/output without needing a human terminal. Every PR.
3. **Live smoke** (manual, not built yet) — a small `examples/` set of Nim programs that the maintainer runs in a real terminal pre-release.

## Commit and PR conventions

- Conventional commits: `feat:`, `fix:`, `refactor:`, `docs:`, `infra:`, `chore:`.
- One issue per PR; reference the issue number.
- Pre-1.0: commit direct to main; no PRs (matches amoxtli's v0 phase).
- No Co-Authored-By trailers, no "Generated with…" footers.

## What not to do

- **Don't introduce a second async runtime.** chronos only.
- **Don't add a VDOM, ever.** Reactivity is signals + compile-time dataflow over the existing per-row diff renderer. See DESIGN.md R1/R4.
- **Don't ship a parallel imperative-widget surface.** T4 is the only user-facing API.
- **Don't shell out to curses or termcap.** Pure ANSI.
- **Don't write to stdout** from library code. stderr or via caller-supplied streams.
- **Don't ship without crash-safe terminal restoration.** A bug that leaves the user's terminal in raw mode is the worst class of defect this library can have.

## When stuck

Read [DESIGN.md](DESIGN.md) end-to-end. Most architectural questions are answered there. If a decision genuinely isn't there, surface it as an issue rather than guessing.
