## test_surface_discharge.nim — RFC-surface-ownership slice 8.
##
## Structural discharge of the soundness obligation:
##   AltScreen ⇒ committedCount = 0
##
## The obligation is discharged at compile time, structurally: AltScreen[S]
## has no `ScrollbackLog` field and no committed-zone procs (`logSink`,
## `logPendingLen`, `logDrainBatch`). Any attempt to reach the committed
## zone on an AltScreen is a compile error. InlineScreen[S] carries the
## full committed-zone surface; `check compiles(…)` positive witnesses
## guard against vacuous pass (a typo that makes all checks trivially pass).
##
## ## Invariant (document once here, canonical)
##
## AltScreen ⇒ committedCount = 0 is discharged STRUCTURALLY:
##   - AltScreen[S] has no `ScrollbackLog` field and no committed-zone procs.
##   - The bad state (committed content in an alt-screen surface) is
##     UNINHABITED — there is no field to hold it, no proc to write it.
##   - This is the type system as the proof. No runtime assert, no Lean.
##
## Soundness over mode transitions is vacuous here: modes are distinct types
## constructed fresh. There is no inline↔alt-screen toggle on a live object;
## you construct one or the other. There is nothing to transition.
##
## When slice 11 adds `appendLine(screen: InlineScreen, line)`, the same
## structural guarantee holds — `appendLine` will only be defined for
## InlineScreen, not AltScreen, and this file's `logSink`-based discharge
## still covers the structural property. Slice 11's own tests can add an
## appendLine-specific check.

{.experimental: "callOperator".}

import std/unittest
import intonaco/reactive
import fresco/render/sink/memory
import fresco/inline_screen
import fresco/altscreen
import fresco/terminal/altscreen_cap

# ---------------------------------------------------------------------------
# Suite 1 — positive witnesses (guard against vacuous pass)
# ---------------------------------------------------------------------------

suite "surface_discharge slice 8: positive witnesses (InlineScreen HAS the committed-zone door)":

  test "InlineScreen.logSink is reachable (positive witness)":
    ## Guards against vacuous pass: if this check failed, every 'not compiles'
    ## on AltScreen below would be trivially true for the wrong reason
    ## (i.e., logSink not existing at all, not existing only on AltScreen).
    let s = newInlineScreen(newMemorySink(), 10, 40)
    check compiles(s.logSink)

  test "InlineScreen.logSink.append is usable (positive witness for usability)":
    ## The committed-zone door is not just reachable — it's a real append
    ## entry point. This is the full positive witness: InlineScreen exposes
    ## a LogSink whose `append` accepts a string.
    let s = newInlineScreen(newMemorySink(), 10, 40)
    check compiles(s.logSink.append("x"))

  test "InlineScreen.logPendingLen is reachable (pipeline accessor positive witness)":
    let s = newInlineScreen(newMemorySink(), 10, 40)
    check compiles(s.logPendingLen)

  test "InlineScreen.logDrainBatch is reachable (pipeline accessor positive witness)":
    let s = newInlineScreen(newMemorySink(), 10, 40)
    check compiles(s.logDrainBatch(1))

# ---------------------------------------------------------------------------
# Suite 2 — negative discharge (AltScreen does NOT have the committed-zone door)
# ---------------------------------------------------------------------------

suite "surface_discharge slice 8: structural discharge (AltScreen LACKS the committed-zone door)":

  test "AltScreen has NO logSink — the primary discharge":
    ## This is the core soundness check. AltScreen[S] has no ScrollbackLog
    ## field and no `logSink` proc. Attempting to reach the committed zone
    ## on an AltScreen is a compile error — the bad state is uninhabited.
    let s = newAltScreen(newMemorySink(), 10, 40, acquireAltScreenGrant(true))
    check not compiles(s.logSink)

  test "AltScreen has NO logPendingLen":
    ## The pipeline-facing accessor does not exist on AltScreen either.
    ## An alt-screen surface cannot even query a pending-line count —
    ## there is no committed buffer to query.
    let s = newAltScreen(newMemorySink(), 10, 40, acquireAltScreenGrant(true))
    check not compiles(s.logPendingLen)

  test "AltScreen has NO logDrainBatch":
    ## The pipeline drain accessor does not exist on AltScreen.
    ## The structural impossibility is complete: no enqueue door, no query,
    ## no drain — committed content is fully absent from AltScreen.
    let s = newAltScreen(newMemorySink(), 10, 40, acquireAltScreenGrant(true))
    check not compiles(s.logDrainBatch(1))
