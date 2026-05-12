## Signals + effects + computed values with runtime dep tracking.
##
## v2.0 implementation: Solid-flavored eager propagation. A signal
## write synchronously runs every registered observer. The compile-
## time static-graph implementation lands in v2.3 as a drop-in for
## the same surface.
##
## API:
##   let count = signal(0)
##   count()         # read (tracked if inside an effect / computed)
##   count.set(5)    # write
##   createEffect(proc() = echo count())
##   let doubled = createComputed(proc(): int = count() * 2)
##
## Tracking: when a Signal is read inside a Computation's body, the
## Signal records the Computation as an observer; the Computation
## records the Signal as a source. On write, observers re-run. On
## scope dispose, the Computation is marked disposed and removed
## from each of its sources' observer lists.

{.experimental: "callOperator".}

import std/macros
import ./scope
import ./subscribable
export subscribable
import ./speculative
import ../journal/events
import ../journal/log

type
  Signal*[T] = ref object of Subscribable
    val: T
    label*: string

# --- Signal -----------------------------------------------------------------

proc signal*[T](initial: T, label = ""): Signal[T] =
  ## Construct a Signal holding `initial`. The optional `label` is
  ## used by the journal for `ekSignalWrite` events — unlabeled
  ## signals are excluded from state-restoration projection.
  Signal[T](val: initial, label: label)

proc get*[T](s: Signal[T]): T {.gcsafe.} =
  ## Read the current value. When called inside a `createEffect` /
  ## `createComputed` body, registers a dynamic dependency on `s`.
  ## Use `peek` to read without tracking.
  trackRead(s)
  s.val

proc peek*[T](s: Signal[T]): T {.gcsafe.} =
  ## Read the current value without registering a dependency on the
  ## current Computation. Use this in code that observes a signal for
  ## side-effects (animation start values, debug logs, journal writes)
  ## but doesn't want to be re-fired when the signal changes.
  s.val

proc `()`*[T](s: Signal[T]): T {.gcsafe.} = s.get()
  ## Sugar — `count()` reads + tracks; same as `count.get()`.

proc setCore[T](s: Signal[T], newVal: T, journal: bool)
    {.gcsafe, raises: [].} =
  when compiles(s.val == newVal):
    # IEEE-754 corner: for Signal[float], `NaN != NaN` so writing NaN
    # over NaN fires observers. For ref signals, identity equality
    # (writing the same ref is a no-op). Both consistent with Nim
    # equality semantics.
    if s.val == newVal: return
  # Push a revert into the active speculative frame, if any. Captures
  # the prior value by closure so a rollback restores it AND notifies
  # observers so dependent effects re-run.
  if currentSpeculative != nil and not currentSpeculative.committed:
    let captured = s
    let prior = s.val
    onSpeculativeRevert proc() =
      captured.val = prior
      notify(captured)
  s.val = newVal
  if journal:
    {.cast(gcsafe).}:
      let valRepr =
        when compiles($newVal): $newVal
        else: ""
      journalEvent:
        jrnl.logSignalWrite(taskTid, parentEvt, s.label, valRepr)
  notify(s)

proc set*[T](s: Signal[T], newVal: T) {.gcsafe, raises: [].} =
  ## Write `newVal` to the signal. Notifies observers and records a
  ## journal entry under the current scope (if any).
  s.setCore(newVal, journal = true)

proc setUntracked*[T](s: Signal[T], newVal: T) {.gcsafe, raises: [].} =
  ## Like `set` but **does not write a journal entry**. Used by the
  ## animation frame clock for intermediate interpolation values:
  ## those writes have no meaningful task attribution (the clock has
  ## no owning user scope) and would bloat the journal anyway. The
  ## terminal animation frame should still go through `set` so the
  ## settled value is journaled.
  s.setCore(newVal, journal = false)

# --- Computations -----------------------------------------------------------

proc createEffect*(body: proc() {.closure.}) {.gcsafe.} =
  ## Run `body` immediately, tracking signal reads; re-run on any
  ## tracked signal's change until the enclosing scope is disposed.
  {.cast(gcsafe).}:
    let comp = Computation()
    comp.run = proc() =
      if comp.disposed: return
      unsubscribeAll(comp)
      let prev = currentComputation
      currentComputation = comp
      try:
        body()
      finally:
        currentComputation = prev
    if currentScope != nil:
      onCleanup proc() =
        comp.disposed = true
        unsubscribeAll(comp)
    comp.run()

template `:=`*[T](s: Signal[T], v: T): untyped =
  ## DSL sugar for signal writes: `count := 5` ≡ `count.set(5)`.
  s.set(v)

macro signals*(body: untyped): untyped =
  ## Declare one or more signals in a colon block:
  ##
  ##   signals:
  ##     count = 0
  ##     title = "hello"
  ##
  ## Named `signals` rather than `state` because chronos exports
  ## `state*(future)` returning FutureState — overload resolution
  ## would shadow our macro any time `import chronos` is in scope.
  ## Single-line `signals x = 0` is not supported — Nim's parser
  ## claims that shape as a named-arg call.
  expectKind(body, nnkStmtList)
  result = newStmtList()
  for stmt in body:
    case stmt.kind
    of nnkAsgn:
      let name = stmt[0]
      let value = stmt[1]
      let labelLit = newLit($name)
      result.add quote do:
        let `name` = signal(`value`, label = `labelLit`)
    else:
      error("signals: arm must be `name = value`; got " &
            stmt.repr, stmt)

proc createComputed*[T](body: proc(): T {.closure.}): Signal[T] {.gcsafe.} =
  ## A derived signal that re-evaluates when its dependencies change.
  ## Reading the returned signal both yields the current value and
  ## subscribes the current computation to it.
  {.cast(gcsafe).}:
    var initial: T
    let outSig = Signal[T](val: initial)
    createEffect proc() =
      outSig.set(body())
    result = outSig
