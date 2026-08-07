## test_busy_gate.nim — RFC headless-quiescence slice B9: the `busy` module.
##
## Per rfc-headless-quiescence.md Design 4 + Slices/B9: `BusyGate` with
## module-private `begin`/`finish` (only `withBusy` can move the counter,
## so an unmatched dec is unrepresentable), the `converter toPredicate*`
## that lets a `BusyGate` stand in directly for a `BusyPredicate` at a
## `drainToIdle`/`settleDrain` call site, and the end-to-end async-turn
## acceptance test (upstream Category B, rfc §Acceptance).
##
## `busy.nim` is general-purpose (not headless-gated): a production
## `TerminalSink` app has the same use for a "syncing..." indicator. This
## test file exercises it standalone (no InlineScreen/MemorySink) except
## for the final e2e test, which proves the converter at the actual
## `drainToIdle` call site named in the RFC.

import std/unittest
import chronos
import intonaco/reactive
import fresco/busy
import fresco/inline_screen
import fresco/render/sink/memory
import fresco/headless/runner

suite "B9: BusyGate — fresh state":

  test "a fresh gate is not busy":
    let g = newBusyGate()
    check not g.isBusy()

suite "B9: BusyGate — withBusy lexical scoping":

  test "isBusy is true inside withBusy and false again after it exits":
    let g = newBusyGate()
    check not g.isBusy()
    withBusy(g):
      check g.isBusy()
    check not g.isBusy()

  test "withBusy releases the gate via finally even when the body raises":
    let g = newBusyGate()
    var raised = false
    try:
      withBusy(g):
        raise newException(ValueError, "boom")
    except ValueError:
      raised = true
    check raised
    check not g.isBusy()  # finally path ran despite the exception

  test "nesting: the gate stays busy after the inner block exits, idle only after the outer exits":
    let g = newBusyGate()
    withBusy(g):
      check g.isBusy()
      withBusy(g):
        check g.isBusy()
      # inner withBusy exited: the outer block is still open, so the
      # counter (not a boolean) must still read busy.
      check g.isBusy()
    check not g.isBusy()

suite "B9: BusyGate — label":

  test "label round-trips from newBusyGate; default is empty":
    check newBusyGate().label() == ""
    check newBusyGate("worker-1").label() == "worker-1"

suite "B9: BusyGate — sealed mutation":

  test "begin/finish are not public: only withBusy can move the counter":
    let g = newBusyGate()
    check not compiles(g.begin())
    check not compiles(g.finish())

suite "B9: BusyGate — converter to BusyPredicate":

  test "a BusyGate converts directly to a BusyPredicate":
    let g = newBusyGate()
    let pred: BusyPredicate = g
    check not pred()
    withBusy(g):
      check pred()
    check not pred()

suite "M5: anyBusy combinator":
  ## Per rfc-headless-quiescence.md M5 (round-1 stage-4 code review):
  ## `anyBusy(gates: varargs[BusyGate]): BusyPredicate` — a single predicate
  ## true iff ANY of `gates` is busy, so multi-gate consumers no longer
  ## hand-roll `proc(): bool = g1.isBusy() or g2.isBusy()`.

  test "anyBusy over two gates flips with either gate and reads false when both are idle":
    let g1 = newBusyGate("g1")
    let g2 = newBusyGate("g2")
    let pred = anyBusy(g1, g2)

    check not pred()

    withBusy(g1):
      check pred()
    check not pred()

    withBusy(g2):
      check pred()
    check not pred()

    withBusy(g1):
      withBusy(g2):
        check pred()
      check pred()  # g1 alone still holds it open
    check not pred()

suite "F2: BusyPredicate compile-time contract via reactive effect tags":
  ## Per the rfc's "BusyPredicate contract" paragraph: `forbids: [ReactiveRead,
  ## ReactiveWrite]` on the proc type makes the context-free half of the
  ## contract compiler-checked, since `Signal.get`/`Dynamic.get` carry
  ## `ReactiveRead` as a real Nim `tags` effect. Proves both directions —
  ## non-vacuity requires the negative case to actually fail to compile.

  test "a closure reading a signal fails to convert to BusyPredicate":
    check not compiles(block:
      let s = signalC(0)
      let bad: BusyPredicate = (proc(): bool {.gcsafe, raises: [].} = s.get() > 0))

  test "a closure writing a signal fails to convert to BusyPredicate":
    ## The ReactiveWrite half of the contract: `Signal.set` routes through
    ## `setCore` -> `setRaw`, and `setRaw` carries `tags: [ReactiveWrite]`
    ## as a declared Nim effect (intonaco
    ## reactive/primitives/signal.nim:74) that infers up through `set`'s
    ## call graph — so a closure that WRITES a signal must fail to convert
    ## to `BusyPredicate` exactly like the read case above, not just the
    ## read half.
    check not compiles(block:
      let s = signalC(0)
      let bad: BusyPredicate = (proc(): bool {.gcsafe, raises: [].} =
        s.set(1)
        false))

  test "a plain Future.finished closure converts to BusyPredicate cleanly":
    proc check1() =
      let f = newFuture[void]("f2-probe")
      let ok: BusyPredicate = (proc(): bool {.gcsafe, raises: [].} = f.finished)
      check ok() == false
    check1()

suite "B9: BusyGate at a real drainToIdle call site (converter, end-to-end)":
  ## Upstream Category B (rfc §Acceptance): an async turn the framework
  ## cannot see on its own (a plain `sleepAsync`, not any reactive or
  ## commit-batcher primitive) must hold the drain open for its full
  ## duration when the app wraps it in `withBusy`. Exercises the RFC's
  ## dependency direction too: headless/runner re-exports BusyPredicate
  ## from busy.nim, not the reverse.

  test "drainToIdle(screen, busy = gate) does not return until the withBusy turn completes":
    proc body() {.async: (raises: [Exception]).} =
      let s = newInlineScreen(newMemorySink(), 5, 20)
      discard s.newRegion(0, 0, 5, 20)
      let gate = newBusyGate("turn")
      var effectLanded = false

      proc turn() {.async: (raises: [Exception]).} =
        withBusy(gate):
          await sleepAsync(30.milliseconds)
          effectLanded = true

      asyncSpawn turn()
      check not effectLanded  # nothing has run yet

      let ok = await drainToIdle(s, busy = gate).withTimeout(2.seconds)
      check ok

      check effectLanded  # the drain did not return before the turn finished
      check not gate.isBusy()

    waitFor body()
