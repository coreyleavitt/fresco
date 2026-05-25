## Reactive bindings from signals to regions.
##
## `bindRow region, idx: expr` opens an effect that evaluates `expr`
## and writes it into `region`'s row `idx` whenever any signal read
## inside `expr` changes. The effect is owned by the current scope,
## so disposing the task or a containing scope tears the binding
## down automatically.
##
##   bindRow region, 0: bold("title")
##   bindRow region, 1: fmt"count: {count()}"
##   bindRows region, 2 ..< region.height - 1: items.map(formatItem)
##
## `bindRows` accepts an HSlice and a body that returns a `seq[string]`.
## Rows in the slice beyond the seq's length are cleared to "". Rows
## outside the region are silently dropped.

import std/macros
import ../screen
import ../render/target
import intonaco/reactive/signal
import intonaco/reactive/collection
import intonaco/reactive/deltafloor   # onDelta — bindCollection's windowed view is
                                      # legitimately dynamic, so it reaches the floor
                                      # explicitly (the greppable classifier-bypass)
import intonaco/reactive/construct

export target

template bindRow*(target: RenderTarget, idx: int, body: untyped) =
  ## Re-evaluate `body` (a string-yielding expression) on every tracked
  ## signal change; write the result into row `idx` of `target`. Routes through
  ## the `effect:` macro, so it's classified at the call site: directly-named
  ## (baked) signal reads schedule statically; anything unresolvable falls to the
  ## sound runtime floor (a warning; an error under `-d:intonacoStrict`).
  effect:
    target.setRow(idx, body)

template bindRows*(target: RenderTarget, slice: HSlice[int, int],
                   body: untyped) =
  ## Re-evaluate `body` (a `seq[string]`-yielding expression) on every
  ## tracked signal change; lay the result into the rows covered by
  ## `slice`. Rows in the slice that don't have a corresponding entry
  ## in the seq are blanked.
  effect:
    let lines = body
    let lo = slice.a
    let hi = slice.b
    if hi >= lo:
      for i in 0 .. (hi - lo):
        let line = if i < lines.len: lines[i] else: ""
        target.setRow(lo + i, line)

# --- Differential binding for CollectionSignal -----------------------------
#
# `bindRows` re-evaluates its whole body on every signal change. For a
# CollectionSignal that emits typed deltas, that's wasteful: a single
# `push` should produce a single new row, not a re-lay of every item.
# `bindCollection` subscribes to deltas and applies them incrementally.
# Fixed window from `items[0]` — see issue #28; scroll-to-end is v3.1.

type WindowMode* = enum
  wmFromStart  ## visible window starts at items[0] (default; legacy behavior)
  wmFromEnd    ## visible window is the tail — last `winLen` items

proc bindCollection*[Target: RenderTarget; T](
    target: Target, slice: HSlice[int, int],
    c: CollectionSignal[T],
    fmt: proc(x: T): string {.closure.},
    mode: WindowMode = wmFromStart) =
  mixin setRow, scrollUp
  ## Lay `c` across `slice` of `region`; on each delta, apply the
  ## minimal row update.
  ##
  ## **mode = wmFromStart** (default): row `slice.a + i` displays
  ## `fmt(items[i])` for `i < min(items.len, slice.len)`; rows
  ## beyond `items.len` are blank.
  ##
  ## **mode = wmFromEnd**: the visible window is the *tail* of the
  ## collection. When `items.len >= winLen`, row `slice.a + i`
  ## displays `fmt(items[items.len - winLen + i])`. When the
  ## collection isn't yet filled, the window degrades to wmFromStart
  ## (items appear top-down from row 0). A push when filled shifts
  ## every visible row's content forward by one; the render layer
  ## may optimize this via scroll-region primitives (see #41).
  ##
  ## Formatter calls are O(1) per delta (new item only) for the
  ## differential ops in wmFromStart; O(winLen) for dkReplace /
  ## dkRollback / push-when-filled-in-wmFromEnd.
  let lo = slice.a
  let hi = slice.b
  if hi < lo: return
  let winLen = hi - lo + 1

  # Cache formatted strings for the visible window only. In wmFromEnd
  # mode the cache mirrors items[items.len - winLen ..< items.len];
  # in wmFromStart mode it mirrors items[0 ..< min(items.len, winLen)].
  var cache: seq[string] = @[]

  proc visibleStartIndex(itemsLen: int): int =
    case mode
    of wmFromStart: 0
    of wmFromEnd:   max(0, itemsLen - winLen)

  proc fmtVisible(items: seq[T]) =
    # Rebuild cache by formatting the currently-visible slice of items.
    cache.setLen(0)
    let start = visibleStartIndex(items.len)
    let stop = min(items.len, start + winLen)
    for i in start ..< stop:
      cache.add fmt(items[i])

  proc layRow(i: int) =
    if i < 0 or i >= winLen: return
    let line = if i < cache.len: cache[i] else: ""
    target.setRow(lo + i, line)

  proc layAll() =
    for i in 0 ..< winLen:
      layRow(i)

  # Initial lay.
  fmtVisible(c.get())
  layAll()

  # Subscribe to deltas — scope-bound via onDelta's internal onCleanup.
  c.onDelta proc(d: Delta[T]) =
    case mode
    of wmFromStart:
      case d.kind
      of dkInsert:
        if d.insertIdx >= winLen: return     # off-screen — nothing to do
        cache.insert(fmt(d.insertVal), d.insertIdx)
        if cache.len > winLen: cache.setLen(winLen)
        for i in d.insertIdx ..< winLen:
          layRow(i)
      of dkRemove:
        if d.removeIdx >= winLen: return     # off-screen
        if d.removeIdx < cache.len: cache.delete(d.removeIdx)
        # If items had more than winLen entries, removing one in the
        # window pulled `items[winLen]` into the visible range — we
        # have to format it (it wasn't cached before).
        let items = c.get()
        if items.len >= winLen and cache.len < winLen:
          cache.add fmt(items[winLen - 1])
        for i in d.removeIdx ..< winLen:
          layRow(i)
      of dkUpdate:
        if d.updateIdx >= winLen: return     # off-screen
        if d.updateIdx < cache.len:
          cache[d.updateIdx] = fmt(d.updateVal)
        layRow(d.updateIdx)
      of dkClear:
        cache.setLen(0)
        layAll()
      of dkReplace:
        fmtVisible(d.replaceVal)
        layAll()
      of dkRollback:
        fmtVisible(c.get())
        layAll()
    of wmFromEnd:
      let items = c.get()
      # Fast path: push-at-end on an already-filled tail-window. The
      # only thing that changes visually is that row 0's content is
      # gone, every row shifts up by one, and the new item appears at
      # the bottom. Emit a single DECSTBM scroll-up + paint the new
      # bottom row — total ANSI = scroll command + one row's worth,
      # regardless of winLen. Conditions:
      #   - insert at the new last index (items.len - 1)
      #   - previous length (items.len - 1) >= winLen, so the window
      #     was already filled (every push would otherwise extend
      #     down rather than scroll)
      if d.kind == dkInsert and
         d.insertIdx == items.len - 1 and
         items.len > winLen:
        cache.delete(0)
        cache.add fmt(d.insertVal)
        # Queue the DECSTBM scroll BEFORE the row updates. At flush:
        # (1) scrollUpRegion emits the scroll command and shifts the
        # renderer's cached snapshot up; (2) layAll updates the
        # region's logical target to the new visible content. The
        # standard target-vs-cache diff then sees rows 0..winLen-2
        # as unchanged (cache shifted to match target) and emits
        # only row winLen-1 (the new bottom). Net ANSI: scroll
        # command + one row's worth of paint.
        when target is ScrollableRenderTarget:
          target.scrollUp(1)
        layAll()
      else:
        # All other deltas in tail mode: any of them can shift the
        # visible slice in either direction. Re-derive cache from
        # items and lay every row. Formatter cost: O(winLen).
        case d.kind
        of dkReplace:
          fmtVisible(d.replaceVal)
        else:
          fmtVisible(items)
        layAll()

template bindCollection*[Target: RenderTarget; T](
    target: Target, slice: HSlice[int, int],
    c: CollectionSignal[T]) =
  ## Convenience overload using `$T` as the formatter.
  bindCollection(target, slice, c, proc(x: T): string = $x)

proc resolveBackIndex(rIdent, expr: NimNode): NimNode =
  ## Rewrite `^N` (from-end index) to `rIdent.height - N`. Leaves
  ## other expressions untouched.
  ##
  ## Only the outermost `^N` is recognized — nested or compound forms
  ## like `(^1 + 1)` aren't rewritten. The common cases (`row ^1:`,
  ## `rows 0..^2:`) cover the v0 surface; reach for an explicit
  ## `r.height - N - 1` if you need arithmetic.
  if expr.kind == nnkPrefix and expr.len == 2 and expr[0].eqIdent("^"):
    let inner = expr[1]
    return quote do: `rIdent`.height - `inner`
  expr

proc resolveSliceEnds(rIdent, slice: NimNode): NimNode =
  ## For a `..` / `..<` infix slice, rewrite ^N on either end. The
  ## `..^` operator (e.g. `1..^2`) is recognized as a single infix
  ## and split into `..` with the right side rewritten.
  if slice.kind != nnkInfix or slice.len != 3:
    return slice
  # eqIdent match against ident-like operators (nnkIdent / nnkSym).
  if slice[0].eqIdent(".."):
    let lo = resolveBackIndex(rIdent, slice[1])
    let hi = resolveBackIndex(rIdent, slice[2])
    return newTree(nnkInfix, slice[0], lo, hi)
  if slice[0].eqIdent("..<"):
    let lo = resolveBackIndex(rIdent, slice[1])
    let hi = resolveBackIndex(rIdent, slice[2])
    return newTree(nnkInfix, slice[0], lo, hi)
  if slice[0].eqIdent("..^"):
    # `lo ..^ n` ≡ `lo .. (rIdent.height - n)`
    let lo = resolveBackIndex(rIdent, slice[1])
    let n  = slice[2]
    let dotDot = ident("..")
    return newTree(nnkInfix, dotDot, lo, quote do: `rIdent`.height - `n`)
  return slice

macro region*(r: untyped, body: untyped): untyped =
  ## DSL block: gather row / rows bindings against a Region.
  ##
  ##   region(panel):
  ##     row 0:        bold("title")
  ##     rows 1..^2:   items()
  ##     row ^1:       fmt"count: {count()}"
  ##
  ## Each arm compiles to bindRow / bindRows; reactivity is owned by
  ## the current scope. `^N` resolves to `r.height - N`, evaluated
  ## each render so it adapts to dynamic resize.
  expectKind(body, nnkStmtList)
  result = newStmtList()
  for arm in body:
    if arm.kind notin {nnkCall, nnkCommand}:
      error("region: expected `row N:` or `rows A..B:` arm; got " &
            arm.repr, arm)
    let head = arm[0]
    let armBody = arm[^1]
    # eqIdent accepts nnkIdent / nnkSym / nnkOpenSymChoice — hygiene
    # may wrap `row` / `rows` as a symbol when this macro is expanded
    # inside another template. Match on the name, not the AST kind.
    if head.eqIdent("row"):
      if arm.len != 3:
        error("region: `row N: body` expects one index argument", arm)
      let idx = resolveBackIndex(r, arm[1])
      result.add quote do:
        bindRow(`r`, `idx`, `armBody`)
    elif head.eqIdent("rows"):
      if arm.len != 3:
        error("region: `rows A..B: body` expects one slice argument", arm)
      if arm[1].kind != nnkInfix:
        error("region: `rows` arm needs an HSlice (`A..B`, `A..<B`, " &
              "`A..^B`) — got `" & arm[1].repr & "`", arm[1])
      let slice = resolveSliceEnds(r, arm[1])
      # Dispatch: if the body is a CollectionSignal, route to the
      # differential `bindCollection`; otherwise the seq[string]-yielding
      # `bindRows`. Detection is via `when compiles(...)` — Nim resolves
      # the right overload at the call site.
      result.add quote do:
        when compiles(bindCollection(`r`, `slice`, `armBody`)):
          bindCollection(`r`, `slice`, `armBody`)
        else:
          bindRows(`r`, `slice`, `armBody`)
    else:
      error("region: unknown arm `" & head.repr & "` (expected `row`/`rows`)", head)
