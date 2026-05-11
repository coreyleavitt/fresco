## Compile-time reactive graph: `tracked:` block.
##
##   tracked:
##     region.setRow(0, fmt"count: {count()}")
##     region.setRow(1, $total())
##
## A typed macro walks the body's AST after Nim's semantic pass,
## identifies every `()` or `.get()` / `.len` call whose receiver has
## type `Signal[T]` or `CollectionSignal[T]`, and emits explicit
## `subscribe(receiver, comp)` edges before the body runs. The body
## itself never touches the runtime `currentComputation` stack — dep
## edges are wired statically.
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
import ./collection

proc trackableTypeName(t: NimNode): string =
  ## If `t` is a `Signal[T]` or `CollectionSignal[T]` bracket-expr,
  ## return the type name; otherwise empty string. Used by the
  ## `tracked:` walker to recognize reactive receivers.
  ##
  ## Comparison is name-based on the type symbol. A user type named
  ## `Signal` or `CollectionSignal` in scope would match the name but
  ## would fail to compile in the subsequent `subscribe(...)` call
  ## (the user type doesn't inherit from `Subscribable`), so the
  ## failure is loud rather than silent.
  ##
  ## **Adding a new Subscribable subtype:** update this list AND
  ## DESIGN.md R10. The `tracked:` macro will not detect reads of
  ## the new type otherwise.
  if t == nil or t.kind != nnkBracketExpr or t.len < 1: return ""
  if t[0].kind != nnkSym: return ""
  let name = $t[0]
  if name == "Signal" or name == "CollectionSignal": name else: ""

proc isReactiveRead(n: NimNode): bool =
  ## True when `n` looks like a call against a `Signal[T]` or
  ## `CollectionSignal[T]` receiver. Detects both `count()` (the `()`
  ## operator) and `count.get()` / `coll.len` (UFCS).
  ##
  ## **Type-alias limitation:** uses `getTypeInst`, which preserves
  ## type aliases as their alias name rather than resolving to the
  ## canonical form. A user with `type AppCount = Signal[int]; let
  ## c: AppCount = signal(0)` would have `c()` reads NOT detected by
  ## `tracked:` — the alias name doesn't match "Signal". Workaround:
  ## use plain `Signal[T]` types directly, or fall back to
  ## `createEffect`. Switching to `getType` resolves aliases but
  ## changes the AST shape (returns ref-of-object structure), which
  ## breaks the common case.
  if n.kind != nnkCall or n.len < 2: return false
  let receiver = n[1]
  var t: NimNode
  try:
    t = receiver.getTypeInst()
  except CatchableError: return false
  trackableTypeName(t).len > 0

const SyntheticKinds = {
  # Compiler-inserted nodes that wrap user expressions during the
  # typed pass. We skip their *subtrees* so a Signal[T] receiver
  # carried inside an implicit conversion or range check doesn't
  # produce a spurious match. Expand this set if Nim adds new
  # synthetic kinds in future releases.
  nnkHiddenCallConv,
  nnkHiddenStdConv,
  nnkHiddenSubConv,
  nnkHiddenDeref,
  nnkHiddenAddr,
  nnkConv,
  nnkChckRange,
  nnkChckRangeF,
  nnkChckRange64,
  nnkStringToCString,
  nnkCStringToString,
}

macro tracked*(body: typed): untyped =
  ## See module docstring.
  var sigs: seq[NimNode] = @[]
  proc walk(n: NimNode) =
    # Skip the synthetic node itself (its kind would never match
    # `isReactiveRead`), but DO recurse into its children — they
    # carry the actual user expressions that may include reactive
    # reads. The earlier "return without recursing" form silently
    # under-subscribed when a Signal read was wrapped in an implicit
    # conversion (e.g., `count()` passed to a `Natural` parameter
    # gets `nnkHiddenStdConv(nnkCall(count_op, count_sym))`).
    if n.kind notin SyntheticKinds and isReactiveRead(n):
      sigs.add n[1]
    for child in n:
      walk(child)
  walk(body)

  let compSym = genSym(nskLet, "comp")
  result = newStmtList()
  result.add quote do:
    let `compSym` = Computation()
  for s in sigs:
    # subscribe() takes a `Subscribable`; both `Signal[T]` and
    # `CollectionSignal[T]` inherit from it, so the same call works
    # for either.
    result.add quote do:
      subscribe(Subscribable(`s`), `compSym`)
  result.add quote do:
    `compSym`.run = proc() {.closure.} = `body`
    onCleanup proc() =
      `compSym`.disposed = true
      unsubscribeAll(`compSym`)
    `compSym`.run()
