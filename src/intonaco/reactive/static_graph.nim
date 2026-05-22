## Compile-time reactive graph: `tracked:` block.
##
##   tracked:
##     region.setRow(0, fmt"count: {count()}")
##     region.setRow(1, $total())
##
## A typed macro walks the body's AST after Nim's semantic pass and
## emits explicit `subscribe(receiver, comp)` edges for every call
## whose receiver structurally satisfies `Subscribable`. The body
## itself never touches the runtime `currentComputation` stack — dep
## edges are wired statically.
##
## ## Detection is type-system-driven
##
## The macro doesn't carry a list of trackable types. For every
## call-shaped expression `f(recv, ...)` in the body, it emits:
##
##   when compiles(subscribe(Subscribable(recv), comp)):
##     subscribe(Subscribable(recv), comp)
##
## The type system decides per-call-site whether `recv` can be upcast
## to `Subscribable` — i.e., whether `recv`'s type inherits from
## `Subscribable`. This naturally handles type aliases
## (`type AppCount = Signal[int]; let c: AppCount; tracked: ...c()...`
## works), generic instances, and any future `ref object of
## Subscribable` user-defined types without macro edits.
##
## ## Conservative over-subscription is intentional
##
## The walker considers every `nnkCall` with at least two children.
## This over-subscribes:
##   - on writes (`s.set(v)` subscribes to `s`) — benign, writes don't
##     re-trigger the writer.
##   - on conditional reads (subscribes to deps in branches the body
##     doesn't currently take) — benign, the effect over-fires but
##     produces correct output.
## Indirect reads through helper procs (`let s = getSignal(); s()`) are
## NOT detected — those need plain `createEffect` for runtime tracking.
##
## ## Cleanup
##
## Same dispose / cleanup semantics as `createEffect`: scope-bound via
## onCleanup, so disposing the enclosing scope unsubscribes the
## computation from every source.

import std/macros
import ./scope
import ./subscribable

const SyntheticKinds = {
  # Compiler-inserted nodes that wrap user expressions during the
  # typed pass. We skip the synthetic node itself (its kind would
  # never be `nnkCall`) but DO recurse into its children — they
  # carry the actual user expressions that may include reactive
  # reads. Expand this set if Nim adds new synthetic kinds in
  # future releases.
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
  var receivers: seq[NimNode] = @[]
  proc walk(n: NimNode) =
    # Record the receiver of every call-shaped node. The `when compiles`
    # guard in the emitted code filters down to actual Subscribable
    # receivers — the walker doesn't need its own type detection.
    if n.kind notin SyntheticKinds and n.kind == nnkCall and n.len >= 2:
      receivers.add n[1]
    for child in n: walk(child)
  walk(body)

  if receivers.len == 0:
    # Almost always a bug — the user wrote `tracked:` expecting reactive
    # re-execution but the body contains no calls (so nothing to detect
    # a Subscribable read on). Common culprits: forgetting `()` on a
    # signal read, or hiding reads behind a helper proc. Emit a hint so
    # the silent-degrade-to-run-once failure mode doesn't bite.
    hint("tracked: block has no detected reactive reads — body will " &
         "run once and never re-fire. Check that signal reads use " &
         "call syntax (count() not count), and that they're not " &
         "hidden behind helper procs (use createEffect for runtime " &
         "tracking of indirect reads).", body)

  let compSym = genSym(nskLet, "comp")
  result = newStmtList()
  result.add quote do:
    let `compSym` = Computation()
  for r in receivers:
    # `when compiles` is the type-system gate. If `Subscribable(r)`
    # compiles (because r's type inherits from Subscribable), the
    # subscribe call is emitted; otherwise the branch is silently
    # dropped at type-check time. Zero detection logic in the macro.
    result.add quote do:
      when compiles(subscribe(Subscribable(`r`), `compSym`)):
        subscribe(Subscribable(`r`), `compSym`)
  result.add quote do:
    `compSym`.run = proc() {.closure.} = `body`
    onCleanup proc() =
      `compSym`.disposed = true
      unsubscribeAll(`compSym`)
    `compSym`.run()
