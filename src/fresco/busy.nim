## busy.nim — general-purpose busy tracking.
##
## `BusyGate` is not headless-gated: a production `TerminalSink` app has
## the same use for a "syncing..." indicator as a headless test has for a
## `drainToIdle` busy clause. `headless/runner.nim` imports and re-exports
## `BusyPredicate` from here (rfc-headless-quiescence.md, §Design 4).
##
## `begin`/`finish` are module-PRIVATE: only `withBusy` can move the
## counter, so an unmatched dec (silent negative count masking real
## busyness) is unrepresentable, not merely discouraged. Precedent:
## LogSink exposes `append` and nothing else; the termios depth counter
## is likewise sealed.

import intonaco/reactive

type
  BusyPredicate* = proc(): bool {.gcsafe, raises: [],
                                  forbids: [ReactiveRead, ReactiveWrite].}
    ## Consumer-supplied "is my own async work still in flight" check.
    ## Must be O(1)-cheap (called every drain iteration) and
    ## context-free — reading plain fields, counters, or `Future.finished`
    ## state, never a scope-dependent reactive read (see rfc
    ## §Design 3, "BusyPredicate contract"). `forbids: [ReactiveRead,
    ## ReactiveWrite]` makes the context-free half of the contract a
    ## compiler-checked property: `Signal.get`/`Dynamic.get` carry
    ## `ReactiveRead` as a real Nim `tags` effect (intonaco
    ## `reactive/primitives/subscribable.nim`), so a closure that reads
    ## one fails to convert to `BusyPredicate` at the assignment site.

  BusyGate* = ref object
    labelStr: string
    count: int

proc newBusyGate*(label = ""): BusyGate = BusyGate(labelStr: label)
proc label*(g: BusyGate): string = g.labelStr
proc isBusy*(g: BusyGate): bool {.inline.} = g.count > 0
proc predicate*(g: BusyGate): BusyPredicate =
  (proc(): bool {.gcsafe, raises: [].} = g.isBusy())
converter toPredicate*(g: BusyGate): BusyPredicate = g.predicate()

proc begin(g: BusyGate) {.inline.} = inc g.count
proc finish(g: BusyGate) {.inline.} = dec g.count

template withBusy*(g: BusyGate, body: untyped) =
  ## Leak-proof by construction: the counter (vs a boolean) is correct
  ## under overlapping/nested turns on the same gate. Instrument each
  ## async await point that should hold a drain's `dcBusy` clause open,
  ## e.g. `withBusy(gate): await state.callDaemon()`.
  g.begin()
  try: body
  finally: g.finish()
