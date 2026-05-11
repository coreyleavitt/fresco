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

proc resolveBackIndex(rIdent, expr: NimNode): NimNode =
  ## Rewrite `^N` (from-end index) to `rIdent.height - N`. Leaves
  ## other expressions untouched.
  ##
  ## Only the outermost `^N` is recognized — nested or compound forms
  ## like `(^1 + 1)` aren't rewritten. The common cases (`row ^1:`,
  ## `rows 0..^2:`) cover the v0 surface; reach for an explicit
  ## `r.height - N - 1` if you need arithmetic.
  if expr.kind == nnkPrefix and expr.len == 2 and
     expr[0].kind == nnkIdent and $expr[0] == "^":
    let inner = expr[1]
    return quote do: `rIdent`.height - `inner`
  expr

proc resolveSliceEnds(rIdent, slice: NimNode): NimNode =
  ## For a `..` / `..<` infix slice, rewrite ^N on either end. The
  ## `..^` operator (e.g. `1..^2`) is recognized as a single infix
  ## and split into `..` with the right side rewritten.
  if slice.kind != nnkInfix or slice.len != 3 or slice[0].kind != nnkIdent:
    return slice
  let op = $slice[0]
  case op
  of "..", "..<":
    let lo = resolveBackIndex(rIdent, slice[1])
    let hi = resolveBackIndex(rIdent, slice[2])
    return newTree(nnkInfix, slice[0], lo, hi)
  of "..^":
    # `lo ..^ n` ≡ `lo .. (rIdent.height - n)`
    let lo = resolveBackIndex(rIdent, slice[1])
    let n  = slice[2]
    let dotDot = ident("..")
    return newTree(nnkInfix, dotDot, lo, quote do: `rIdent`.height - `n`)
  else:
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
    if head.kind != nnkIdent:
      error("region: arm head must be `row` or `rows`", head)
    case $head
    of "row":
      if arm.len != 3:
        error("region: `row N: body` expects one index argument", arm)
      let idx = resolveBackIndex(r, arm[1])
      result.add quote do:
        bindRow(`r`, `idx`, `armBody`)
    of "rows":
      if arm.len != 3:
        error("region: `rows A..B: body` expects one slice argument", arm)
      if arm[1].kind != nnkInfix:
        error("region: `rows` arm needs an HSlice (`A..B`, `A..<B`, " &
              "`A..^B`) — got `" & arm[1].repr & "`", arm[1])
      let slice = resolveSliceEnds(r, arm[1])
      result.add quote do:
        bindRows(`r`, `slice`, `armBody`)
    else:
      error("region: unknown arm `" & $head & "` (expected `row`/`rows`)", head)
