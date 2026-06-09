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
## ## Bottom-anchor contract
##
## InlineScreen regions are bottom-anchored — they occupy the last rows
## of the terminal. For a terminal of height H and a band of k rows,
## place regions at rows `H-k .. H-1` (0-based). Committed content
## spills into rows `0 .. H-k-1` above the band and into native
## terminal scrollback when those rows fill up.
##
## Example: `pinnedHeaderRows=2`, H=24 → band rows 22 and 23 (0-based):
##
## ```nim
## let header = s.newRegion(s.height - 2, 0, 1, s.width)
## let prompt  = s.newRegion(s.height - 1, 0, 1, s.width)
## ```
##
## Placing regions at the top (rows 0, 1) while calling `commit` is
## incorrect: committed content would overwrite rows above the band
## that don't exist, or the terminal would have nowhere to scroll
## committed lines into.
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

import chronos
import intonaco/reactive
import ./render/layout
import ./render/sink
import ./render/timing
import ./terminal/ansi as ansiMod
import ./terminal/termios as termiosMod

export timing.AutoPaintInterval

export layout.Region, layout.set, layout.markDirty, layout.setRow,
       layout.scrollUp, layout.rows, layout.resizeRows, layout.reclipRows

const kCommitBatch* = 256
  ## Per-batch watermark for the inline commit pipeline. The synchronous
  ## drain loop takes up to kCommitBatch lines per iteration; the async
  ## multi-batch yield logic (slice 10c) uses this to bound work per tick.

# ---------------------------------------------------------------------------
# Private type: ScrollbackLog
# ---------------------------------------------------------------------------

type
  ScrollbackLog = ref object
    ## Append-only committed-zone buffer. PRIVATE to this module.
    ## Bindings never receive a ScrollbackLog — only a LogSink.
    pending: seq[string]
      ## Buffered committed lines since the last takeBatch call.
    notify: proc() {.gcsafe.}
      ## Installed by newInlineScreen after construction.
      ## Called by append after every enqueue. The closure captures the
      ## screen and calls scheduleCommit. nil until the screen is wired.

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
      ## Derived live-band height: ``max(0, size[0] - pinnedHeaderRows)``.
      ## Updates reactively when ``size`` changes (chronos dispatcher turn).
      ##
      ## Two usage modes:
      ##
      ## (1) Reactive / ``bindScrollback`` — the live band always shows the
      ##     last ``liveZoneHeight`` collection items; older items overflow
      ##     into committed scrollback.  Here ``liveZoneHeight`` equals the
      ##     live-tail height = ``H - pinnedHeaderRows`` (the full band
      ##     minus the fixed chrome rows reserved at the bottom).
      ##
      ## (2) Imperative — the consumer places bottom-anchored regions
      ##     directly via ``newRegion(s, row, col, h, w)``.  Here
      ##     ``liveZoneHeight`` serves only as the "terminal tall enough to
      ##     spill" guard in the commit pipeline (the zero-height clamp).
      ##     The consumer is responsible for placing regions so that
      ##     ``max(r.row + r.height) == layout.height`` (bottom-anchor
      ##     contract) — the commit pipeline enforces this at runtime.
      ##
      ## ``pinnedHeaderRows`` is the reserved fixed-chrome height: rows
      ## at the bottom of the terminal that are never part of the live band.
      ## The live band must be bottom-anchored — its lowest edge must reach
      ## terminal row ``H`` (see the bottom-anchor contract enforcement in
      ## ``commitOneBatch``).
      ##
      ## Dynamic[int] (not Signal[int]) because the dependency is a
      ## closure-captured Signal parameter; the ``dynamic`` macro's
      ## runtime-floor auto-tracking is the right tool.
      ## Readable as a call: ``s.liveZoneHeight()``.
    pinnedHeaderRows*: int
      ## Baked at construction. Fixed chrome height (v0 bound — see RFC).
    pendingCommit: bool
      ## Dirty flag: set by append on the first enqueue of an idle log.
      ## Test-and-cleared by the commit pipeline (S3 slice 10c).
      ## INTERNAL — write access is reserved for the pipeline.
    commitInProgress: bool
      ## Auto-paint gate: set when the pipeline begins, cleared after
      ## the final batch. runAutoPaint skips paint while set (S3).
      ## INTERNAL — write access is reserved for the pipeline.
    inputRow*: int
      ## Live band's declared cursor-home row (0-based). Set by the caller
      ## to position the cursor after each commit. Default: 0.
    inputCol*: int
      ## Live band's declared cursor-home column (0-based). Set by the caller
      ## to position the cursor after each commit. Default: 0.
    commitRuns: int
      ## Incremented once per full commit (driveCommitStep first entry OR
      ## synchronous commit*) that actually drains (logPendingLen > 0).
      ## INTERNAL — read via commitRunsCount() test seam.
    stagedH: int
      ## Staged height from a setSize call that arrived mid-burst.
      ## Applied when the burst completes (finishCommit). Default: 0.
      ## INTERNAL — no legitimate external write contract.
    stagedW: int
      ## Staged width from a setSize call that arrived mid-burst.
      ## Applied when the burst completes (finishCommit). Default: 0.
      ## INTERNAL — no legitimate external write contract.
    hasStagedSize: bool
      ## True iff a setSize arrived while commitInProgress was set.
      ## Cleared and applied by finishCommit. Default: false.
      ## INTERNAL — no legitimate external write contract.

# ---------------------------------------------------------------------------
# LogSink ops — append is the SOLE public door
# ---------------------------------------------------------------------------

proc append*(s: LogSink, line: string) =
  ## Enqueue a committed line into the log.
  ## Sanitizes via `sanitizeLogLine` (single chokepoint): strips C0 controls,
  ## non-SGR CSI, non-OSC-8 OSC sequences. Neither appendLine nor bindScrollback
  ## sanitize — all content passes through here.
  s.log.pending.add(ansiMod.sanitizeLogLine(line))
  # Mirror the updated pending seq into the static tail buffer so the crash
  # handler can flush it async-signal-safely. Lines are already sanitized.
  termiosMod.setInlineTail(s.log.pending)
  if s.log.notify != nil:
    s.log.notify()

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

proc appendLine*[S: Sink](s: InlineScreen[S], line: string) =
  ## Imperative one-shot enqueue for banners, prompts, and other committed
  ## content. Routes through `logSink.append` (the single sanitize chokepoint).
  s.logSink.append(line)

# ---------------------------------------------------------------------------
# Auto-paint gate predicate (private layout helper)
# ---------------------------------------------------------------------------

proc anyPendingLayout(layout: Layout): bool =
  for r in layout.regions:
    if r.pending or r.pendingScroll != 0: return true
  false

# ---------------------------------------------------------------------------
# Shared single-batch emit body
# ---------------------------------------------------------------------------
# commitOneBatch must be forward-declared here as a concept because the
# generic body uses `mixin` to defer `commitInline`/`writeAll` resolution.
# It is defined after the constructors section (below) where it can see
# the full InlineScreen[S] type — both forms are in scope for Nim's
# two-pass resolution of generic instantiation.

proc commitOneBatch[S: Sink](s: InlineScreen[S]): string

# ---------------------------------------------------------------------------
# scheduleCommit / driveCommit — the async-trigger machinery
#
# Implementation note: driveCommit is NOT an {.async.} proc. Generic async
# procs in this chronos version have a known instantiation-site macro-
# expansion issue: `sleepAsync` returns an `InternalRaisesFuture[void,
# (CancelledError,)]`, which requires `internalRaiseIfError(fut, raises, info)`
# (3-arg form) to be visible at instantiation time. In modules that import
# inline_screen but not chronos directly, this macro is not in scope, causing
# "attempting to call undeclared routine: internalRaiseIfError". Rather than
# require every consumer to import chronos, we implement the yield-between-
# batches step via callSoon (a plain proc call) which is directly callable
# without the async machinery. callSoon schedules a `proc(pointer){.gcsafe.}`
# on the dispatcher's callback queue — exactly one dispatcher turn of latency.
# ---------------------------------------------------------------------------

proc scheduleCommit[S: Sink](s: InlineScreen[S])  # forward decl for notify

proc driveCommitStep[S: Sink](s: InlineScreen[S]) {.gcsafe, raises: [].}

proc applySizeNow*[S: Sink](s: InlineScreen[S], h, w: int)  # forward decl for finishCommit

proc finishCommit*[S: Sink](s: InlineScreen[S])  # forward decl for driveCommitStep

proc assertDrained[S: Sink](s: InlineScreen[S]) {.inline.} =
  ## Assert that the log is fully drained and no region is pending.
  ## Called from both the async (driveCommitStep) and sync (commit*) paths
  ## so the invariant is auditable at both exit points. No-op when assertions
  ## are disabled (compileOption("assertions") is false).
  when compileOption("assertions"):
    doAssert s.logPendingLen() == 0,
      "commit: log not empty after full drain"
    for r in s.layout.regions:
      doAssert (not r.pending) and r.pendingScroll == 0,
        "commit: region still pending/scrolling after drain"

proc scheduleCommit[S: Sink](s: InlineScreen[S]) =
  ## Idempotent: if already scheduled or a batch chain is in flight, return.
  ## A running driveCommit loops until logPendingLen==0 and will pick up
  ## any newly-appended lines, so a second schedule is never needed.
  if s.pendingCommit or s.commitInProgress:
    return
  s.pendingCommit = true
  # Schedule one dispatcher turn away. callSoon takes CallbackFunc =
  # proc(pointer){.gcsafe, raises:[].}. We wrap in a closure via a tiny
  # proc that discards the pointer argument.
  let capture = s
  proc cb(p: pointer) {.gcsafe, raises: [].} =
    try: driveCommitStep(capture)
    except CatchableError: discard
  callSoon(cb, nil)

proc driveCommitStep[S: Sink](s: InlineScreen[S]) {.gcsafe, raises: [].} =
  ## One step of the bounded-latency multi-batch driver.
  ## On the FIRST call (pendingCommit was set): clear flag, set commitInProgress,
  ## drain one batch, then re-schedule if more remain.
  ## commitInProgress spans ALL batches (cleared only on final drain or
  ## zero-height clamp) so auto-paint cannot interleave mid-burst.
  if not s.commitInProgress:
    # First entry: test-and-clear the pending flag.
    s.pendingCommit = false
    if s.logPendingLen() == 0:
      return
    inc s.commitRuns
    s.commitInProgress = true

  # Per-batch step: drain one batch.
  # Zero-height clamp: band not open; preserve pending, stop.
  if s.liveZoneHeight.get() <= 0:
    finishCommit(s)
    return

  discard commitOneBatch(s)

  if s.logPendingLen() > 0:
    # More remain. Yield one dispatcher turn then continue.
    # commitInProgress stays true across the gap.
    let capture = s
    proc cb(p: pointer) {.gcsafe, raises: [].} =
      try: driveCommitStep(capture)
      except CatchableError: discard
    callSoon(cb, nil)
  else:
    assertDrained(s)
    finishCommit(s)

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
  # Use get(size) inside the `dynamic` body rather than the call operator
  # `size()[0]`, because compilation units that import both inline_screen
  # and fresco/render/sink/terminal (which transitively pulls in std/unicode
  # via ansi.nim) introduce `unicode.size(Rune): int` into scope. The
  # call-operator `()` then becomes ambiguous between `Signal.()` and
  # `unicode.size`, causing an "attempting to call routine" error during
  # generic instantiation. `get(size)[0]` resolves unambiguously because
  # there is no competing `get` in unicode.
  dynamic liveZoneHeight:
    max(0, get(size)[0] - ph)
  let scr = InlineScreen[S](
    layout: newLayout(h, w),
    log: log,
    sink: sink,
    size: size,
    liveZoneHeight: liveZoneHeight,
    pinnedHeaderRows: pinnedHeaderRows,
    pendingCommit: false,
    commitInProgress: false,
    inputRow: 0,
    inputCol: 0,
    commitRuns: 0,
    stagedH: 0,
    stagedW: 0,
    hasStagedSize: false,
  )
  scr.log.notify = proc() {.gcsafe.} = scheduleCommit(scr)
  scr

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
# Test seams — narrow observable windows into internal pipeline state.
# Named with a *ForTest suffix for write-path seams to make misuse visible.
# ---------------------------------------------------------------------------

proc commitRunsCount*[S: Sink](s: InlineScreen[S]): int =
  ## Number of commit runs (driveCommit first entries OR synchronous commit
  ## calls) that actually drained at least one line. Test-observable batch counter.
  s.commitRuns

proc isCommitInProgress*[S: Sink](s: InlineScreen[S]): bool =
  ## True while a multi-batch async burst is in flight. Test-observable gate.
  s.commitInProgress

when defined(frescoTesting):
  proc setCommitInProgressForTest*[S: Sink](s: InlineScreen[S], v: bool) =
    ## Forcibly set commitInProgress. Test seam ONLY — absent from production
    ## builds (compiled only when `-d:frescoTesting` is set). Lets tests
    ## simulate a mid-burst state without running a real async pipeline.
    ## The `when defined(frescoTesting)` wrapper ensures the WRITE trapdoor
    ## into invariant-critical state does not exist in production binaries.
    s.commitInProgress = v

# ---------------------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------------------

proc height*[S: Sink](s: InlineScreen[S]): int {.inline.} = s.layout.height
proc width*[S: Sink](s: InlineScreen[S]): int {.inline.}  = s.layout.width

proc newRegion*[S: Sink](s: InlineScreen[S],
    row, col, height, width: int): Region =
  newRegion(s.layout, row, col, height, width)

# ---------------------------------------------------------------------------
# Resize — setSize + deferred-write discipline (S3 slice 12)
# ---------------------------------------------------------------------------

proc applySizeNow*[S: Sink](s: InlineScreen[S], h, w: int) =
  ## Immediately apply new dimensions to the layout, clamp all regions,
  ## re-clip existing rows to the new width (the fix for screen.nim's
  ## latent bug where resizeRows does not re-clip existing rows), mark
  ## all regions pending, and write the reactive size signal.
  ##
  ## Must only be called when commitInProgress is false — it mutates
  ## geometry. setSize enforces this via the deferred-write discipline.
  mixin invalidate
  s.layout.height = h
  s.layout.width  = w
  when compiles(s.sink.invalidate()):
    s.sink.invalidate()
  for r in s.layout.regions:
    if r.row >= h:
      r.height = 0
    elif r.row + r.height > h:
      r.height = h - r.row
    if r.col >= w:
      r.width = 0
    elif r.col + r.width > w:
      r.width = w - r.col
    r.resizeRows(r.height)
    # Re-clip existing rows to the new width via the shared layout helper.
    # (Previously inlined here as `let cur = r.rows; for i in ...: r.setRow(i, cur[i])`;
    # now delegates to reclipRows so all three resize paths share one implementation.)
    r.reclipRows()
    r.pending = true
  s.size.set((h, w))

proc finishCommit*[S: Sink](s: InlineScreen[S]) =
  ## Clear commitInProgress and, if a resize was staged during the burst,
  ## apply it now on this clean turn.
  s.commitInProgress = false
  if s.hasStagedSize:
    s.hasStagedSize = false
    applySizeNow(s, s.stagedH, s.stagedW)

proc setSize*[S: Sink](s: InlineScreen[S], h, w: int) =
  ## Resize the inline live band (width AND height). If a commit burst is
  ## in flight (commitInProgress), STAGE the new size and apply it on the
  ## next clean turn after the burst drains — never mutate geometry mid-batch.
  if s.commitInProgress:
    s.stagedH = h
    s.stagedW = w
    s.hasStagedSize = true
    return
  applySizeNow(s, h, w)

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

# ---------------------------------------------------------------------------
# Inline commit pipeline (S3 slice 10+10b — synchronous)
#
# Drains the committed-line log in batches, runs each batch through the
# byte-capture pipeline in `terminal.commitInline`, and writes the
# resulting bytes to the sink. Returns the accumulated byte string (the
# seam for tests). The async dirty-flag / callSoon scheduling is slice 10c.
# ---------------------------------------------------------------------------

type
  BandNotBottomAnchoredDefect* = object of Defect
    ## Raised by `commit` when the live band is not bottom-anchored — its lowest
    ## region does not reach the terminal's bottom row, so committed content has
    ## nowhere to spill into native scrollback (the InlineScreen scrollback model
    ## breaks). This is a CONSUMER-CONTRACT violation (a programming error in the
    ## caller's region placement), not an internal fresco assertion — hence its
    ## own named `Defect` rather than `AssertionDefect`. It is a `Defect` so it
    ## is exempt from the `{.raises.}` effect system (it can surface from the
    ## `{.raises: [].}` async commit driver) and is NOT elided under `-d:danger`
    ## (it is a real `raise`, not a `doAssert`).

proc commitOneBatch[S: Sink](s: InlineScreen[S]): string =
  ## Drain one batch from the log through the sink. Returns the emitted bytes
  ## (empty string for non-TerminalSink paths). Does NOT touch commitInProgress.
  ## Zero-height clamp: if liveZoneHeight <= 0, returns "" without draining.
  ##
  ## This is the single shared emit body used by both `commit*` (synchronous
  ## full-drain) and `driveCommit` (async multi-batch driver). One implementation
  ## of the emit logic — no drift between the sync and async paths.
  mixin commitInline, writeAll

  if s.liveZoneHeight.get() <= 0:
    return ""

  let batch = s.logDrainBatch(kCommitBatch)
  if batch.len == 0:
    return ""
  # Mirror the now-smaller pending seq into the tail buffer after the drain.
  termiosMod.setInlineTail(s.log.pending)

  # Design-2: fail-fast on a non-bottom-anchored band.
  # The bottom-anchor contract requires that committed content spills from the
  # top of the live band upward into native scrollback. If regions exist but
  # the band's lowest edge does NOT reach the terminal bottom, the terminal
  # has nowhere for committed lines to spill — the scrollback model breaks.
  # Invariant: max(r.row + r.height) over all regions == s.layout.height.
  if s.layout.regions.len > 0:
    var lowestEdge = 0
    for r in s.layout.regions:
      let edge = r.row + r.height
      if edge > lowestEdge:
        lowestEdge = edge
    if lowestEdge != s.layout.height:
      raise newException(BandNotBottomAnchoredDefect,
        "InlineScreen commit requires a bottom-anchored band: " &
        "lowest region must reach terminal row " & $s.layout.height &
        " (got " & $lowestEdge & "). " &
        "Place regions at rows H-bandHeight .. H-1 (0-based).")

  # Compute liveTop = min r.row over all regions (0 if no regions).
  var liveTop = 0
  if s.layout.regions.len > 0:
    liveTop = s.layout.regions[0].row
    for r in s.layout.regions:
      if r.row < liveTop:
        liveTop = r.row

  # Dispatch to the sink-appropriate batch handler.
  # TerminalSink: commitInline handles the full pipeline (steps 2,4,5,6,7)
  #   including the physicalRows cursor-accounting assertion.
  # Other sinks (MemorySink etc.): no committed-line emit; repaint live band.
  when compiles(s.sink.commitInline(s.layout, batch, liveTop, 0, 0)):
    let bytes = s.sink.commitInline(s.layout, batch, liveTop,
                                    s.inputRow, s.inputCol)
    s.sink.writeAll(bytes)
    result = bytes
  else:
    s.paint()

proc teardownFlush*[S: Sink](s: InlineScreen[S]) =
  ## Teardown flush: fully drain any buffered committed lines RAW
  ## (`line + "\n"`, cursor-unanchored) followed by a final `"\n"`.
  ## GUARANTEE: the committed tail is fully drained — zero bytes dropped.
  ## The live-band frame is intentionally NOT repainted: the physical cursor
  ## position is unknown at teardown time, so repainting at Region.row would
  ## land the band in the wrong rows.
  ##
  ## After draining, explicitly disarms the static inline-tail buffer so
  ## that the subsequent restoreAllAndReraise/flushInlineTailNow call is a
  ## structural no-op rather than a coincidental one. This enforces the
  ## invariant: "after teardownFlush, the static tail is disarmed/empty."
  ##
  ## ASYNC-SIGNAL-SAFETY: this is an EXPLICIT-call contract invoked from the
  ## consumer's NORMAL shutdown path (e.g. the chronos watch task that wakes
  ## on the self-pipe), NOT from the async signal handler itself —
  ## draining heap `pending` strings + a write loop are not async-signal-safe.
  ## The fatal-signal handler does only the termios restore + alt-screen leave
  ## + static-buffer flush, which ARE async-signal-safe. The lines are already
  ## sanitized (LogSink.append chokepoint), so emit them as-is.
  ##
  ## MemorySink (no scrollback model): still disarms the tail buffer so the
  ## structural invariant holds regardless of sink type.
  mixin writeAll
  let n = s.logPendingLen()
  if n > 0:
    let batch = s.logDrainBatch(n)   # drain ALL
    when compiles(s.sink.fd):   # TerminalSink path (has a real fd to write to)
      var bytes = ""
      for line in batch: bytes &= line & "\n"
      bytes &= "\n"
      s.sink.writeAll(bytes)
    elif compiles(s.sink.committedRows):   # MemorySink capture path
      for line in batch: s.sink.committedRows.add(line)
    # else (unknown sink): drained but not emitted — no scrollback to capture.
  # Explicitly disarm the static tail buffer. On the graceful path this makes
  # the flushInlineTailNow() call inside restoreAllAndReraise a structural
  # no-op. On the crash path teardownFlush never runs, so the tail stays armed
  # for the signal handler to flush. Either way: no double-emit, nothing dropped.
  termiosMod.disarmInlineTail()

proc commit*[S: Sink](s: InlineScreen[S]): string {.discardable.} =
  ## Synchronous full-drain commit. Batch-loops until the log is empty.
  ##
  ## Regions must be bottom-anchored (rows `H-bandHeight .. H-1`); see the
  ## module-level bottom-anchor contract. Committed content spills into the
  ## rows above the band and then into native terminal scrollback.
  ##
  ## Pipeline order (enforced inside commitInline):
  ##   2. Pre-drain pendingScroll for live-band regions.
  ##   3. cursorTo(liveTop+1, 1) + ED 0 — clear old band.
  ##   4. Emit N committed lines raw + band rows as relative-flow \n stream.
  ##   5. Invalidate live-band renderer cache; mark regions pending=false.
  ##   6. cursor → inputRow/inputCol.
  ##
  ## TerminalSink: commitInline computes the bytes (including physicalRows
  ##   cursor-accounting assertion); writeAll writes them.
  ## Other sinks: fall back to paint (live band only; committed lines not emitted).
  ##
  ## `mixin commitInline, writeAll` allows the generic to find the TerminalSink
  ## procs at instantiation time (via the caller's import scope) without
  ## inline_screen.nim importing terminal.nim (which would pull in posix and
  ## conflict with the Signal call-operator resolution in the constructors).
  mixin commitInline, writeAll
  s.commitInProgress = true

  # Zero-height clamp: if the live band is 0 rows, the committed output has
  # nowhere to spill (no band to scroll from). Preserve pending, return empty.
  if s.liveZoneHeight.get() <= 0:
    finishCommit(s)
    return ""

  # Only count as a run if there is actually something to drain.
  if s.logPendingLen() > 0:
    inc s.commitRuns

  # Batch loop: synchronous full-drain via the shared commitOneBatch body.
  while s.logPendingLen() > 0 and s.liveZoneHeight.get() > 0:
    result &= commitOneBatch(s)

  assertDrained(s)

  finishCommit(s)

# ---------------------------------------------------------------------------
# Auto-paint + shouldAutoPaint predicate (slice 10c)
# ---------------------------------------------------------------------------

proc shouldAutoPaint*[S: Sink](s: InlineScreen[S]): bool =
  ## True iff auto-paint should fire: no commit in progress AND a region is
  ## pending. Exposed as a testable predicate so tests can assert suppression
  ## without racing the 33ms timer.
  (not s.commitInProgress) and anyPendingLayout(s.layout)

proc runAutoPaint*[S: Sink](s: InlineScreen[S]) {.async.} =
  ## Long-running task that paints the live band whenever a region is dirty
  ## AND no commit pipeline is in flight. Same lifecycle shape as Screen's
  ## runAutoPaint: opt-in, explicit cancel, no entanglement with the constructor.
  while true:
    await sleepAsync(AutoPaintInterval)
    if shouldAutoPaint(s):
      paint(s)

# ---------------------------------------------------------------------------
# bindScrollback — reactive overflow spill into LogSink
# ---------------------------------------------------------------------------

proc bindScrollbackImpl[T](sink: LogSink, liveHeight: Dynamic[int],
    c: CollectionSignal[T], fmt: proc(x: T): string {.closure.}) =
  ## Internal (non-gcsafe) implementation. bindScrollback is the public shim.
  ##
  ## Semantics (v0, append-growth focused):
  ##   - Track `committed` = count of items already spilled to scrollback.
  ##   - On any delta, re-evaluate overflow = max(0, items.len - liveHeight.get()).
  ##   - If overflow > committed: spill items[committed ..< overflow] via sink.append.
  ##   - Shrink/remove/clear do NOT rewrite committed history (terminal owns scrollback).
  ##
  ## Reads liveHeight.get() at call time — handles resize without re-binding.
  var committed = 0

  proc spill() =
    let items = c.get()
    let overflow = max(0, items.len - liveHeight.get())
    if overflow > committed:
      for i in committed ..< overflow:
        sink.append(fmt(items[i]))
      committed = overflow

  spill()  # initial evaluation

  eachDelta c, d:
    spill()

proc bindScrollback*[T](sink: LogSink, liveHeight: Dynamic[int],
    c: CollectionSignal[T],
    fmt: proc(x: T): string {.closure.}) {.gcsafe.} =
  ## Spill overflow items from `c` into `sink` as the collection grows past
  ## `liveHeight`. Items beyond the last `liveHeight` entries are committed to
  ## scrollback via `sink.append` (single-writer sanitize chokepoint).
  ##
  ## v0 limitation: shrink/clear/replace do NOT rewrite already-committed history.
  ## The terminal owns scrollback; previously spilled content is permanent.
  ##
  ## gcsafe shim: fresco runs on a single chronos dispatcher; the cast is
  ## sound (mirrors bindCollection's pattern).
  {.cast(gcsafe).}:
    bindScrollbackImpl(sink, liveHeight, c, fmt)

template bindScrollback*[T](sink: LogSink, liveHeight: Dynamic[int],
    c: CollectionSignal[T]) =
  ## Convenience overload using `$T` as the formatter (mirrors bindCollection).
  bindScrollback(sink, liveHeight, c, proc(x: T): string {.gcsafe.} = $x)
