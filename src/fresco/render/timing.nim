## render/timing.nim — shared timing constants for the auto-paint loop.
##
## Lives here (not in screen.nim or inline_screen.nim) so both can import
## a single canonical definition without pulling each other's heavier
## transitive deps. This module imports only chronos (for the Duration
## type and the `milliseconds` literal) — no terminal, no unicode.
##
## Consumers:
##   screen.nim        — Screen[S].runAutoPaint
##   inline_screen.nim — InlineScreen[S].runAutoPaint

import chronos

const AutoPaintInterval* = 33.milliseconds
  ## Auto-paint cadence (~30fps). Each tick costs a microseconds-scale
  ## O(regions) dirty-flag check when nothing has changed; far below
  ## human-perceptible latency and far above a busy input loop's event rate.
