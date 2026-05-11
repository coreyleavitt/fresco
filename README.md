# fresco

[![CI](https://github.com/coreyleavitt/fresco/actions/workflows/ci.yml/badge.svg)](https://github.com/coreyleavitt/fresco/actions/workflows/ci.yml)

A minimal terminal-UI kernel for Nim — raw-mode input event stream, region-based rendering, composable widgets. Designed for CLI agents and other long-running interactive programs that need an always-live input surface alongside streamed output.

Inspired by [Ink](https://github.com/vadimdemedes/ink) (React-for-terminals) but written from primitives appropriate for Nim's strengths: chronos async, no VDOM unless the use case demands it, no Yoga-style flexbox layout engine until something needs it. Build the 10% you'll actually use; defer the rest.

## Status

Pre-v0. Architecture in [DESIGN.md](DESIGN.md). Issues track all real work.

## Why fresco?

A fresco is composed in panels — multiple painters can work on different sections concurrently, restoration repaints just the affected area, the surface "sets" so the composition persists. Maps cleanly to a terminal UI kernel: components are panels, the screen state is the wet plaster, redraw is restoration.

## License

MIT. The whole point of building it as a sibling library to [amoxtli](https://github.com/coreyleavitt/amoxtli) is that it should also be useful to other projects.
