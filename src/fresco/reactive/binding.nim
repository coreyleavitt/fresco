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
