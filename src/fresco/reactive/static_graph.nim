## Compile-time reactive graph: `tracked:` block.
##
##   tracked:
##     region.setRow(0, fmt"count: {count()}")
##     region.setRow(1, $total())
##
## A typed macro walks the body's AST after Nim's semantic pass,
## identifies every `()` or `.get()` call whose receiver has type
## `Signal[T]`, and emits explicit `subscribe(signal, comp)` edges
## before the body runs. The body itself never touches the runtime
## `currentComputation` stack — dep edges are wired statically.
##
## Conservative semantics: the macro subscribes to *every* signal it
## can detect, including those only read in conditional branches.
## Over-subscription is sound (the effect may over-fire on a dep that
## isn't actually read in the current path) but never under-subscribes.
## Indirect reads — `let s = getSignal(); s()` — aren't detectable;
## those need plain `createEffect` so the runtime stack tracks them.
##
## Same dispose / cleanup semantics as `createEffect`: scope-bound
## via onCleanup, so disposing the enclosing scope unsubscribes the
## computation from every source.

import std/macros
import ./scope
import ./signal

proc isSignalRead(n: NimNode): bool =
  ## True when `n` looks like a call against a `Signal[T]` receiver.
  ## Detects both `count()` (`()` operator) and `count.get()` (UFCS).
  if n.kind != nnkCall or n.len < 2: return false
  let receiver = n[1]
  var t: NimNode
  try:
    t = receiver.getTypeInst()
  except CatchableError: return false
  if t == nil or t.kind != nnkBracketExpr or t.len < 1: return false
  t[0].kind == nnkSym and $t[0] == "Signal"

const SyntheticKinds = {
  nnkHiddenCallConv,
  nnkHiddenStdConv,
  nnkHiddenSubConv,
  nnkHiddenDeref,
  nnkHiddenAddr,
  nnkConv,
}

macro tracked*(body: typed): untyped =
  ## See module docstring.
  var sigs: seq[NimNode] = @[]
  proc walk(n: NimNode) =
    # Skip compiler-synthesized nodes whose contents would otherwise
    # produce spurious Signal[T] matches on inserted conversions.
    if n.kind in SyntheticKinds: return
    if isSignalRead(n):
      sigs.add n[1]
    for child in n:
      walk(child)
  walk(body)

  let compSym = genSym(nskLet, "comp")
  result = newStmtList()
  result.add quote do:
    let `compSym` = Computation()
  for s in sigs:
    result.add quote do:
      subscribe(`s`, `compSym`)
  result.add quote do:
    `compSym`.run = proc() {.closure.} = `body`
    onCleanup proc() =
      `compSym`.disposed = true
      unsubscribeAll(`compSym`)
    `compSym`.run()
