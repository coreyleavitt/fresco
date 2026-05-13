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
import ./signal
import ./scope
import ./collection

template bindRow*(region: Region, idx: int, body: untyped) =
  ## Re-evaluate `body` (a string-yielding expression) on every tracked
  ## signal change; write the result into row `idx` of `region`.
  createEffect proc() =
    region.setRow(idx, body)

template bindRows*(region: Region, slice: HSlice[int, int],
                   body: untyped) =
  ## Re-evaluate `body` (a `seq[string]`-yielding expression) on every
  ## tracked signal change; lay the result into the rows covered by
  ## `slice`. Rows in the slice that don't have a corresponding entry
  ## in the seq are blanked.
  createEffect proc() =
    let lines = body
    let lo = slice.a
    let hi = slice.b
    if hi >= lo:
      for i in 0 .. (hi - lo):
        let line = if i < lines.len: lines[i] else: ""
        region.setRow(lo + i, line)

# --- Differential binding for CollectionSignal -----------------------------
#
# `bindRows` re-evaluates its whole body on every signal change. For a
# CollectionSignal that emits typed deltas, that's wasteful: a single
# `push` should produce a single new row, not a re-lay of every item.
# `bindCollection` subscribes to deltas and applies them incrementally.
# Fixed window from `items[0]` — see issue #28; scroll-to-end is v3.1.

proc bindCollection*[T](region: Region, slice: HSlice[int, int],
                        c: CollectionSignal[T],
                        fmt: proc(x: T): string {.closure.}) =
  ## Lay `c` across `slice` of `region`; on each delta, apply the
  ## minimal row update. Row `slice.a + i` displays `fmt(items[i])`
  ## for `i < min(items.len, slice.len)`; rows beyond items.len are
  ## blank. Formatter calls are O(1) per delta (new item only) for
  ## the differential ops; O(items.len) for dkReplace/dkRollback.
  let lo = slice.a
  let hi = slice.b
  if hi < lo: return
  let winLen = hi - lo + 1

  # Cache formatted strings for the visible window only. Items past
  # `winLen` are never formatted — they're off-screen. The cache
  # mirrors the visible portion of the collection: `cache[i]` is the
  # rendered text of `items[i]` for `i < min(items.len, winLen)`.
  var cache: seq[string] = @[]

  proc fmtVisible(items: seq[T]) =
    # Rebuild cache from `items`, formatting only the visible prefix.
    cache.setLen(0)
    let n = min(items.len, winLen)
    for i in 0 ..< n:
      cache.add fmt(items[i])

  proc layRow(i: int) =
    if i < 0 or i >= winLen: return
    let line = if i < cache.len: cache[i] else: ""
    region.setRow(lo + i, line)

  proc layAll() =
    for i in 0 ..< winLen:
      layRow(i)

  # Initial lay.
  fmtVisible(c.get())
  layAll()

  # Subscribe to deltas — scope-bound via onDelta's internal onCleanup.
  c.onDelta proc(d: Delta[T]) =
    case d.kind
    of dkInsert:
      if d.insertIdx >= winLen: return       # off-screen — nothing to do
      cache.insert(fmt(d.insertVal), d.insertIdx)
      if cache.len > winLen: cache.setLen(winLen)
      for i in d.insertIdx ..< winLen:
        layRow(i)
    of dkRemove:
      if d.removeIdx >= winLen: return       # off-screen
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
      if d.updateIdx >= winLen: return       # off-screen
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
      # Collection has already applied the inverses; re-derive cache
      # from the current state. Formatter cost is O(winLen).
      fmtVisible(c.get())
      layAll()

template bindCollection*[T](region: Region, slice: HSlice[int, int],
                            c: CollectionSignal[T]) =
  ## Convenience overload using `$T` as the formatter.
  bindCollection(region, slice, c, proc(x: T): string = $x)

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
