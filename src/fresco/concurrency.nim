## Single-dispatcher enforcement (#50).
##
## fresco's design (DESIGN.md → "Concurrency model") assumes a single
## chronos dispatcher per process. Several runtime invariants depend
## on this: chronos's contextvar storage, `typeMarker` first-touch,
## the animation frame clock's threadvars, and the POSIX signal
## handler stack are all single-thread-by-construction.
##
## Most of these failure modes are documented but not enforced. The
## journal layer is different: a multi-thread host that opens the
## same PersistentJournal from two threads (or two dispatchers) gets
## silent, persistent disk corruption. This module is the runtime
## guardrail that catches that case loudly.
##
## ## Usage
##
##   import fresco/concurrency
##   ...
##   assertDispatcherThread()   # call before any disk-corruption-prone op
##
## First call stamps the current thread as fresco's dispatcher.
## Subsequent calls from a different thread raise
## `MultiDispatcherError`. The stamp is process-global via a single
## atomic CAS, so genuine multi-thread races resolve deterministically
## — the first thread to call wins; everyone else fails closed.
##
## ## Testing override
##
## `dispatcherProbe` is an overridable proc returning "current thread
## id." Defaults to system.getThreadId. Tests replace it to simulate
## cross-thread calls without requiring `--threads:on` for the whole
## suite.

import std/atomics

type
  MultiDispatcherDefect* = object of Defect
    ## Raised when fresco code runs on a thread other than the one
    ## that first stamped the dispatcher. Defect (not CatchableError)
    ## by design: this is a programmer-error invariant violation,
    ## not a runtime condition. Propagates through `raises: []`
    ## constraints (so journal methods, signal mutators, etc. can
    ## still call `assertDispatcherThread` without changing their
    ## signatures) and is meant to terminate the process loudly.

var dispatcherProbe* {.threadvar.}: proc(): int {.gcsafe, raises: [].}
  ## Overridable probe for the current thread id. Per-thread so each
  ## thread can install its own simulated id during tests. In production
  ## the probe is initialized lazily to `system.getThreadId` on first
  ## use.

var dispatcherThreadStamp: Atomic[int]
  ## Process-global stamp. 0 = unbound; non-zero = bound to that
  ## thread id. Set on first `assertDispatcherThread` call via CAS.

proc probe(): int {.inline, raises: [].} =
  ## Resolve the current thread id, defaulting to the OS one when
  ## no test override is installed for this thread.
  if dispatcherProbe == nil:
    dispatcherProbe = proc(): int {.gcsafe, raises: [].} = getThreadId()
  dispatcherProbe()

proc assertDispatcherThread*() {.raises: [].} =
  ## Stamp the current thread as fresco's dispatcher on first call;
  ## raise `MultiDispatcherError` on subsequent calls from a different
  ## thread. Idempotent for same-thread re-entry.
  let cur = probe()
  var expected = 0
  if dispatcherThreadStamp.compareExchange(expected, cur):
    return     # we just installed it; we're the dispatcher
  if expected != cur:
    raise newException(MultiDispatcherDefect,
      "fresco called from thread " & $cur & " but the dispatcher " &
      "is bound to thread " & $expected & ". fresco supports a single " &
      "dispatcher thread; see DESIGN.md (Concurrency model).")

proc resetDispatcherThread*() =
  ## Clear the stamp. Intended for tests that set up fresh state
  ## between cases. Production code shouldn't need this.
  dispatcherThreadStamp.store(0)
