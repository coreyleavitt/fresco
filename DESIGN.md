# fresco — Design

> Source of truth for architecture and locked decisions. Issues reference section anchors here.

## Vision

A terminal-UI **kernel** (not a framework) for Nim. Provides:
- Raw-mode stdin → async keypress event stream
- Region-based rendering with smart line-update (no full-screen flicker)
- A small set of composable widgets (select, input, scrollback, status bar)
- Crash-safe terminal mode restoration

What it explicitly is NOT:
- A virtual DOM or React reconciler (caller manages state)
- A flexbox layout engine (caller positions regions explicitly)
- A theming framework (just expose ANSI primitives; caller styles)
- A monolithic event loop (chronos already provides one; fresco hooks in)

The wedge is **kernel, not framework**: solve the hard parts (raw-mode TTY, render-without-clobber, async input throughout) once and well, leave composition + state to the caller. This is what makes it useful for both [recall](https://github.com/coreyleavitt/recall) and any other Nim CLI that needs a serious interactive surface.

## Identity

- **Language**: Nim 2.x
- **Async**: chronos (matches recall; no std/asyncdispatch)
- **Rendering**: ANSI escape sequences (no curses dependency, no termcap parsing)
- **Layout**: region-based (caller specifies row/col bounds for each region; fresco renders within them)
- **License**: MIT
- **Distribution**: Nimble package; sibling-library to recall

---

## Locked decisions

| # | Topic | Decision |
|---|---|---|
| L1 | Language + async | Nim 2.x + chronos. Same constraints as recall: ARC/ORC, no std/asyncdispatch mixing, taskpools for CPU-bound work. |
| L2 | Library, not framework | Expose primitives + small widgets; caller composes. No "fresco-app" runtime that owns main. |
| L3 | Single input source | Raw-mode `STDIN_FILENO` → chronos AsyncEvent stream. All keys flow through here; consumers subscribe with handlers. No sync `readLine` calls anywhere in fresco code. |
| L4 | Region-based rendering | Caller declares regions (row/col, height/width); fresco tracks dirty state per region and re-renders only what changed. No VDOM for v0. |
| L5 | ANSI sequences | Direct emission via stderr (preserves stdout for piping). No curses. We have +98% terminal compat with bare ANSI. |
| L6 | Crash safety | Termios saved at session start; restored via `defer` + signal handlers (SIGTERM, SIGINT, SIGSEGV). Worst case the user can `reset` their terminal but our code does its best. |
| L7 | No theme system | Caller passes ANSI sequences directly (or uses the small `style` helpers). Themes are 10 lines of config in the caller, not a fresco concern. |
| L8 | Dev tooling | Docker for all toolchain ops (Nim, nimble, tests). OpenSUSE Tumbleweed base, mirroring recall. `./dev` shell wrapper. |
| L9 | Test strategy | Tier 1: pure unit (event-stream parser, region geometry, ANSI builder). Tier 2: integration with mock TTY (PTY-based). Tier 3: live smoke against a real terminal (manual). |
| L10 | First release | v0 = T1+T2 (input + region rendering + select widget). Sufficient for recall to drop in for permission prompt + live commands during turns. |

---

## Architecture (T1-T4)

The work is naturally tiered. Each tier is shippable; later tiers compose on earlier.

### Tier 1: Input event stream + termios + ANSI primitives

```
src/fresco/
├── terminal/
│   ├── termios.nim     # save/restore + cbreak/raw mode
│   ├── ansi.nim         # cursor positioning, line clear, color, styles
│   └── signals.nim      # SIGWINCH, SIGTERM/INT cleanup hooks
├── input.nim            # raw stdin → chronos AsyncQueue[KeyEvent]
├── events.nim           # KeyEvent type + decode (escape sequences → semantic keys)
└── fresco.nim           # public API entry
```

**Deliverable**: a Nim program can `await fresco.nextKey()` in a loop and get parsed key events (`KeyEnter`, `KeyChar('a')`, `KeyArrowUp`, `KeyCtrlC`, etc.). Terminal restored on any exit path.

**Size**: ~600 LoC + ~300 LoC tests.

### Tier 2: Region rendering + select widget

```
src/fresco/
├── screen.nim           # Screen abstraction: width/height, cursor, region tracking
├── region.nim           # Region: bounded surface for one widget
├── render.nim           # Smart line-update: diff intended vs current, emit minimal ANSI
└── widgets/
    ├── select.nim       # Single-select menu (arrow keys, number keys, Ctrl-C)
    ├── input.nim        # Single-line text input (with history optional)
    └── status.nim       # Bottom status line (always-visible, doesn't get clobbered)
```

**Deliverable**: a permission-prompt-class UI works end-to-end. `select` widget renders, accepts keys, returns the chosen option. Output above the widget (model streaming) doesn't clobber the widget.

**Size**: ~800 LoC + ~400 LoC tests.

### Tier 3: Multi-region layout + scrollback

```
src/fresco/
├── layout.nim           # Stack regions vertically (no flexbox; just a list)
├── scrollback.nim       # Append-only scrollback buffer with viewport
└── widgets/
    ├── diff.nim         # Side-by-side or unified file diff
    ├── review.nim       # Prompt + diff + approve/reject (composite)
    └── progress.nim     # Inline progress indicator (multiple concurrent)
```

**Deliverable**: file diffs, multi-line review prompts, multiple concurrent progress indicators (e.g. several bg shells, each showing a spinner + label).

**Size**: ~1200 LoC + ~500 LoC tests.

### Tier 4: Reactive component model (deferred until needed)

VDOM-style diffing + a hooks-equivalent for component state. Only build when a recall or external use case actually needs it; T1+T2+T3 covers everything in recall's current roadmap.

---

## Out of scope

- Windows console (we target POSIX TTYs in v0; Windows is v1+ if anyone asks)
- Mouse input (deferred)
- Image rendering (sixel / kitty graphics — separate library)
- Notifications / bells
- Localization beyond UTF-8 width-aware rendering

## Open questions

- Whether to expose a `fresco.run(component)` runtime sugar in v0 or push that to v1 — depends on how recall's integration looks.
- How to handle terminal resize mid-render (queue a redraw on SIGWINCH? force immediately?). T2 question.
