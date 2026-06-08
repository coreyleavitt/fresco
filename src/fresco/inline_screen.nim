## InlineScreen — inline (bottom-anchored) surface ownership.
##
## InlineScreen[S] is the "modern-CLI" surface shape: a small live
## (pinned, diff-cached) band at the bottom of the terminal, with all
## committed content spilling into native terminal scrollback above it.
##
## Unlike AltScreen, InlineScreen does NOT own the full screen. It owns
## only the bottom band (`liveZoneHeight` rows). Everything above is
## committed output — printed once via native scroll and never
## addressed again.
##
## ## Type-level single-writer guarantee
##
## `ScrollbackLog` is PRIVATE to this module. The only handle bindings
## and callers receive is `LogSink`, which exposes exactly one door:
## `append`. `takeBatch` and `pendingLen` live on the private
## `ScrollbackLog` and are invisible to `LogSink` holders. The
## single-writer invariant is structural — the symbol doesn't exist
## on `LogSink`.
##
## ## Constructors
##
## Primary: `newInlineScreen(sink, size, pinnedHeaderRows)` — size is
## a caller-owned `Signal[(int,int)]`; the SIGWINCH handler writes it
## and liveZoneHeight reacts.
##
## Convenience: `newInlineScreen(sink, h, w, pinnedHeaderRows)` —
## wraps a constant signal (tests, static layouts).
##
## ## Pinned rendering
##
## InlineScreen's pinned `Layout` + `Sink` render path is byte-for-byte
## identical to Screen[S] and AltScreen[S]. Region allocation, set,
## markDirty, setRow, paint — all delegate to the same Layout + Sink
## machinery. No separate renderer is needed.

{.experimental: "callOperator".}

import intonaco/reactive
import ./render/layout
import ./render/sink

export layout.Region, layout.set, layout.markDirty, layout.setRow,
       layout.scrollUp, layout.rows, layout.resizeRows

# ---------------------------------------------------------------------------
# Private type: ScrollbackLog
# ---------------------------------------------------------------------------

type
  ScrollbackLog = ref object
    ## Append-only committed-zone buffer. PRIVATE to this module.
    ## Bindings never receive a ScrollbackLog — only a LogSink.
    pending: seq[string]
      ## Buffered committed lines since the last takeBatch call.

# ---------------------------------------------------------------------------
# Public types
# ---------------------------------------------------------------------------

type
  LogSink* = object
    ## Capability view of the committed zone: enqueue-only.
    ## The ONLY handle bindings and external callers receive.
    ## Exposes `append` and nothing else — `takeBatch`/`pendingLen`/
    ## the underlying ScrollbackLog are structurally absent.
    log: ScrollbackLog   # field NOT exported

  ScreenView* = object
    ## Flat value object for screen-agnostic APIs that need both layout
    ## and size. Passed explicitly — no concept, no implicit coupling.
    ## Per the RFC: distinct InlineScreen/AltScreen share no concept;
    ## ScreenView is the opt-in projection for genuinely agnostic APIs.
    layout*: Layout
    size*: Signal[(int, int)]

  InlineScreen*[S: Sink] = ref object
    layout*: Layout
      ## Holds only pinned Regions. Layout.regions is homogeneous pinned
      ## (no kind flag) — render()'s hot loop never branches on kind.
    log: ScrollbackLog
      ## The committed zone (private). Only the pipeline calls takeBatch.
    sink*: S
    size*: Signal[(int, int)]
      ## Caller-owned; the SIGWINCH handler writes it.
    liveZoneHeight*: Dynamic[int]
      ## Derived: max(0, size[0] - pinnedHeaderRows). Updates reactively
      ## when size changes. Dynamic[int] (not Signal[int]) because the dep
      ## is a closure-captured Signal parameter, not a compile-time-listed
      ## dep — the `dynamic` macro's runtime-floor auto-tracking is the
      ## right tool here. Readable via `s.liveZoneHeight()`.
    pinnedHeaderRows*: int
      ## Baked at construction. Fixed chrome height (v0 bound — see RFC).
    pendingCommit*: bool
      ## Dirty flag: set by append on the first enqueue of an idle log.
      ## Test-and-cleared by the commit pipeline (S3 slice 10c).
    commitInProgress*: bool
      ## Auto-paint gate: set when the pipeline begins, cleared after
      ## the final batch. runAutoPaint skips paint while set (S3).

# ---------------------------------------------------------------------------
# LogSink ops — append is the SOLE public door
# ---------------------------------------------------------------------------

proc append*(s: LogSink, line: string) =
  ## Enqueue a committed line into the log.
  # slice 11: sanitize here (strip \n/\r/C0-controls/motion-CSI/state-OSC,
  # keep SGR) before enqueueing.
  s.log.pending.add(line)

# ---------------------------------------------------------------------------
# Pipeline-private ops — NOT exported (no asterisk)
# ---------------------------------------------------------------------------

proc takeBatch(log: ScrollbackLog, max: int): seq[string] =
  ## Hand off up to `max` lines from the pending queue, clearing them.
  ## Pipeline-private: only the commit pipeline (InlineScreen-internal)
  ## calls this. Not reachable from a LogSink.
  let n = min(max, log.pending.len)
  result = log.pending[0 ..< n]
  log.pending = log.pending[n .. ^1]

proc pendingLen(log: ScrollbackLog): int =
  ## Buffered line count. Pipeline-private trigger condition and drain
  ## assertion. Not on the public LogSink surface.
  log.pending.len

# ---------------------------------------------------------------------------
# Expose LogSink from InlineScreen
# ---------------------------------------------------------------------------

proc logSink*[S: Sink](s: InlineScreen[S]): LogSink =
  ## The only handle bindings get. Returns a LogSink wrapping the
  ## screen's private ScrollbackLog. Binding captures this; disposing
  ## the screen's scope tears down the binding.
  LogSink(log: s.log)

# ---------------------------------------------------------------------------
# Constructors
# ---------------------------------------------------------------------------

proc newInlineScreen*[S: Sink](sink: S, size: Signal[(int, int)],
    pinnedHeaderRows = 1): InlineScreen[S] =
  ## Primary constructor. Accepts a caller-owned size signal — the
  ## SIGWINCH handler writes it and liveZoneHeight reacts.
  let (h, w) = get(size)
  let log = ScrollbackLog(pending: @[])
  let ph = pinnedHeaderRows
  # Derive liveZoneHeight reactively from size using the `dynamic` macro.
  # `dynamic` auto-tracks reactive reads in the body at runtime — the right
  # tool here since `size` is a closure-captured parameter, not a
  # compile-time-listed dep. The result is Dynamic[int] (not Signal[int]);
  # readable via `s.liveZoneHeight()` via the call operator.
  dynamic liveZoneHeight:
    max(0, size()[0] - ph)
  InlineScreen[S](
    layout: newLayout(h, w),
    log: log,
    sink: sink,
    size: size,
    liveZoneHeight: liveZoneHeight,
    pinnedHeaderRows: pinnedHeaderRows,
    pendingCommit: false,
    commitInProgress: false,
  )

proc newInlineScreen*[S: Sink](sink: S, h, w: int,
    pinnedHeaderRows = 1): InlineScreen[S] =
  ## Static-size convenience: wraps a constant signal around (h, w).
  ## Used by tests and any caller that doesn't need reactive resize.
  newInlineScreen(sink, signalC((h, w)), pinnedHeaderRows)

# ---------------------------------------------------------------------------
# Pipeline-facing accessors (on InlineScreen, NOT on LogSink)
# These are the pipeline's own view of the log — the commit engine (S3)
# calls these. They are NOT on LogSink, so the structural single-writer
# guarantee holds: a LogSink holder cannot drain or inspect the buffer.
# ---------------------------------------------------------------------------

proc logPendingLen*[S: Sink](s: InlineScreen[S]): int =
  ## Number of committed lines buffered and awaiting the pipeline.
  ## Used by the S3 commit trigger + drain assertion.
  pendingLen(s.log)

proc logDrainBatch*[S: Sink](s: InlineScreen[S], max: int): seq[string] =
  ## Hand off up to `max` buffered committed lines, clearing them.
  ## Called by the S3 commit pipeline (the sole drainer).
  ## NOT available on LogSink — structural single-writer guarantee.
  takeBatch(s.log, max)

# ---------------------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------------------

proc height*[S: Sink](s: InlineScreen[S]): int {.inline.} = s.layout.height
proc width*[S: Sink](s: InlineScreen[S]): int {.inline.}  = s.layout.width

proc newRegion*[S: Sink](s: InlineScreen[S],
    row, col, height, width: int): Region =
  newRegion(s.layout, row, col, height, width)

# ---------------------------------------------------------------------------
# Paint — identical to Screen[S] and AltScreen[S]
# ---------------------------------------------------------------------------

proc paint*[S: Sink](s: InlineScreen[S]) =
  ## Commit the pinned layout through the sink.
  ## Byte-identical to Screen.paint / AltScreen.paint.
  mixin commit
  s.sink.commit(s.layout)

# ---------------------------------------------------------------------------
# ScreenView projection
# ---------------------------------------------------------------------------

proc screenView*[S: Sink](s: InlineScreen[S]): ScreenView =
  ## Project to the flat value object for screen-agnostic APIs.
  ScreenView(layout: s.layout, size: s.size)
