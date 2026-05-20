# fresco

[![CI](https://github.com/coreyleavitt/fresco/actions/workflows/ci.yml/badge.svg)](https://github.com/coreyleavitt/fresco/actions/workflows/ci.yml)

The terminal frontend of a three-package reactive system for Nim. Raw-mode input event stream, region-based rendering, composable widgets, async on chronos, ANSI-only.

## The three packages

```
fresco              — terminal frontend (this repo; terminal-exclusively)
  ↓ depends on
intonaco            — pure reactive substrate (signals, scopes, supervision,
                      journal, capabilities — frontend-agnostic)
  ↑ depends on
sinopia             — trace frontend; emits structured time-series events
                      instead of painting to a surface. Validates intonaco's
                      portability and provides observability for fresco apps.
```

The names map literally to three layers of Renaissance fresco-making: *intonaco* is the smooth plaster paint goes onto, *sinopia* is the red-pigment preparatory underdrawing made on it, and the *fresco* is the finished painting. All three packages are siblings; fresco does not own the reactive primitives.

Companion repos:
- [coreyleavitt/intonaco](https://github.com/coreyleavitt/intonaco) — substrate (private during transition)
- [coreyleavitt/sinopia](https://github.com/coreyleavitt/sinopia) — trace frontend (private; pre-implementation)

The current single-repo `fresco` package contains both substrate and terminal code today; the mechanical split into three packages is Phase 3 of [the split RFC](docs/rfc-intonaco-fresco-split.md). Public API for terminal consumers will continue to come from `fresco` post-split.

## Status

v0.1.0 released. Pre-1.0; commits direct to main, conventional commits.

Architecture in [DESIGN.md](DESIGN.md). RFC suite in [docs/](docs/) covers the substrate split, terminal interaction model, observability substrate, devtools UX, sinopia, and a roadmap of compile-time research directions.

## Why fresco is terminal-exclusively

The original framing of fresco as a "terminal-UI kernel" conflated substrate and frontend. Restoring the boundary: substrate primitives (reactive graph, supervision, journal, caps) belong in intonaco; row-based 2D rendering and ANSI emission belong in fresco. Any future render frontend (sinopia, hypothetical web, voice, bot) is a sibling, not a sub-component.

This means fresco can be opinionated about terminal-specific things — termios restore, ANSI capability detection, region-based diff rendering, terminal-shaped hotkey vocabulary — without those opinions leaking into the substrate.

## License

Apache 2.0.
