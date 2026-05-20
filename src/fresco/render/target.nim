## RenderTarget — fresco's abstraction over row-based render surfaces.
##
## A `RenderTarget` is any value supporting per-row text writes plus a
## queryable height. fresco's terminal `Region` is the canonical impl;
## a forthcoming `HeadlessRenderTarget` provides an in-memory impl for
## CI assertion + testing. Future fresco-extension frontends (file,
## web embedded in terminal-shape) implement their own.
##
## ## Scope
##
## RenderTarget is terminal-domain. It assumes a row-based render
## model (`setRow(idx, content)`) — the natural fit for terminals,
## CI assertion output, and headless test capture. **It is NOT an
## intonaco substrate concept.** Frontends with fundamentally
## different render models (a web frontend operating on DOM nodes;
## a voice frontend with no spatial output) define their own
## abstractions in their own packages.
##
## intonaco's contract for any frontend is `createEffect` — the
## reactive primitive. Everything above that (RenderTarget,
## bindings, layout) is frontend-specific glue.

type
  RenderTarget* = concept t
    ## A row-addressable text render surface.
    ## - `setRow(idx, content)` writes a row at zero-based index `idx`.
    ##   Out-of-bounds indexes are silently dropped (the impl decides).
    ## - `height` is the row count; used by binding macros for
    ##   `^N` (from-end) slice notation and bounds.
    t.setRow(0, "")
    t.height is int

  ScrollableRenderTarget* = concept t of RenderTarget
    ## A RenderTarget that supports DECSTBM-style scroll-region
    ## semantics. `bindCollection`'s `wmFromEnd` fast-path uses this
    ## to emit a scroll command instead of repainting every row when
    ## a new item appends to a filled tail-window.
    ##
    ## Terminal targets (Region) implement this. Headless targets
    ## and most other frontends typically don't — bindings fall back
    ## to per-row repaints, which is correct but slower.
    t.scrollUp(1)
