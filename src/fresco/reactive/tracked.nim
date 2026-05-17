## Static dep-graph inference for effects (#56).
##
## `trackedEffect: body` registers a reactive effect AND statically
## extracts the set of labeled signals the body reads. The extraction
## walks the body's typed AST looking for nodes whose type is
## `Signal[T]` — that catches `sig.get()`, `sig()`, `sig.peek()`,
## and `sig.val` uniformly, since all bind to a `Signal[T]` symbol
## somewhere in the call chain.
##
## # Usage
##
##   let title = signal("", label = "title")
##   let count = signal(0, label = "count")
##   let eff = trackedEffect:
##     render(title(), count())
##   echo effectDeps(eff)   # @["title", "count"]
##
## # Static vs dynamic deps
##
## Static: the dep set is the union of all signals the body's AST
## syntactically reads. Conditional reads (`if c: a() else: b()`)
## contribute `@["a", "b"]` regardless of which branch actually
## fires at runtime. This is the over-reporting trade-off filed in
## #56 — devtools rendering the dep edges sees a superset of the
## actual reactive deps the runtime tracker observed, which is fine
## for human inspection (better to show all possible edges than to
## hide a sometimes-active one).
##
## # Anonymous signals
##
## Signals declared without a `label = ...` argument have
## `s.label == ""`. They're excluded from the static dep set —
## labels are how downstream consumers (devtools, persistence)
## identify a signal across module/runtime boundaries, and empty
## labels would collide into one indistinguishable bucket.
##
## # Relationship to the R4 architectural intent
##
## DESIGN.md R4 says fresco's reactive graph SHOULD be compile-time
## static dataflow. Today the runtime still maintains a tracking
## stack (`Computation.sources`) — that debt is tracked at #65.
## `trackedEffect:` here is the first piece of the static path:
## the dep set is computed at compile time and attached to the
## Computation as constant data. The runtime tracking continues
## to operate alongside; a future #65 migration would replace it.

import std/[hashes, macros, tables]
import ./signal
import ./subscribable

proc hash(c: Computation): Hash {.inline.} = hash(cast[pointer](c))
  ## Hash a Computation by pointer identity — the natural key for a
  ## ref-keyed runtime table. `std/tables` needs an explicit `hash`
  ## overload for ref-object keys.

var effectDepsTable {.threadvar.}: Table[Computation, seq[string]]
  ## Runtime registry mapping each tracked Computation to its
  ## statically-extracted label set. Threadvar because fresco is
  ## single-dispatcher; cross-thread visibility isn't a concern.

proc registerEffectDeps*(c: Computation, deps: seq[string]) =
  ## Internal: associate a Computation with the dep set that the
  ## `trackedEffect:` macro extracted from its body. Called by the
  ## macro's emitted code immediately after `createEffect` returns.
  effectDepsTable[c] = deps

proc effectDeps*(c: Computation): seq[string] =
  ## Return the statically-extracted labels for an effect created
  ## via `trackedEffect:`. Empty seq for effects not registered.
  if c in effectDepsTable: effectDepsTable[c] else: @[]

proc isSignalType(node: NimNode): bool =
  ## True when `node` is a Sym whose type is `Signal[T]` for some T.
  ## Used by the AST walker to identify signal-typed expressions.
  if node.kind != nnkSym: return false
  let typ = node.getTypeInst
  if typ.kind == nnkBracketExpr and typ.len >= 1:
    return typ[0].repr == "Signal"
  false

proc isSignalReadCall(call: NimNode): bool =
  ## True when `call` is a function-call node whose callee operates
  ## on a Signal — i.e., the first argument's type is `Signal[T]`.
  ## Matches `s.get()`, `s()`, `s.peek()` uniformly because the
  ## typed AST resolves all three to nnkCall with the signal as
  ## the first positional argument.
  if call.kind notin {nnkCall, nnkCommand}: return false
  if call.len < 2: return false                  # need a receiver
  isSignalType(call[1])

proc literalLabel(sym: NimNode): string =
  ## Best-effort extraction of a labeled signal's `label` string.
  ## Walks the symbol's definition AST looking for the `signal(...)`
  ## call that created it. Nim's typed AST has already resolved
  ## keyword args to positional, so `signal(0, label = "n")` shows
  ## up as `Call(signal, IntLit 0, StrLit "n")` — the second
  ## positional arg is the label.
  ##
  ## Returns "" if the label can't be determined statically
  ## (unlabeled signal, signal created via a non-literal expression,
  ## or signal whose binding the macro can't trace).
  if sym.kind != nnkSym: return ""
  let impl = sym.getImpl
  if impl.kind == nnkNilLit: return ""
  # `let n = signal(0, "n")` impl is an IdentDefs whose last child
  # is the rhs Call. Some forms (var, const, identdefs from a
  # multi-decl) may differ; descend to the last child.
  var value = impl[^1]
  if value.kind notin {nnkCall, nnkCommand}: return ""
  # Identify the call as a `signal` factory. The callee is a Sym
  # whose repr is "signal" (or a fully-qualified variant).
  if value.len < 1: return ""
  let callee = value[0]
  if callee.kind != nnkSym: return ""
  if callee.repr != "signal": return ""
  # Args: [initial, label]. Label is the second positional arg.
  if value.len < 3: return ""
  let labelArg = value[2]
  if labelArg.kind == nnkStrLit: return labelArg.strVal
  ""

proc collectLabels(node: NimNode, found: var seq[string]) =
  ## Recursively walk `node` looking for signal-read calls. Each
  ## hit's receiver symbol contributes its literal label (if any)
  ## to `found`. Dedups so multiple reads of the same signal
  ## register only once.
  if node == nil: return
  if isSignalReadCall(node):
    let label = literalLabel(node[1])
    if label.len > 0 and label notin found:
      found.add label
  for child in node:
    collectLabels(child, found)

macro trackedEffect*(body: typed): untyped =
  ## Block macro: creates a reactive effect from `body` AND
  ## registers its statically-extracted dep set on the returned
  ## Computation. Returns the Computation so callers can store it
  ## (e.g., for `effectDeps(c)` queries).
  ##
  ## **Typed AST.** Receives the body post-sem so signal-typed
  ## expressions resolve uniformly across `s.get()`, `s()`,
  ## `s.peek()`, `s.val` — all bind to a `Signal[T]` symbol the
  ## walker can detect. The `tracked:` macro form (no createEffect)
  ## was considered but the closure-creation pattern matches the
  ## existing `createEffect proc() = body` style; a block that
  ## directly creates the effect is the natural fit.
  var deps: seq[string]
  collectLabels(body, deps)
  let depsLit = newLit(deps)
  result = quote do:
    block:
      var capturedComp: Computation
      createEffect proc() =
        if capturedComp == nil:
          capturedComp = currentComputation
        `body`
      registerEffectDeps(capturedComp, `depsLit`)
      capturedComp
