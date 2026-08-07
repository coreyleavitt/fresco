## test_surface_probes.nim — RFC headless-quiescence slice B4: surface idle
## probes.
##
## `commitIdle` (InlineScreen commit batcher settled) and `surfaceIdle`
## (commitIdle AND no unpainted dirty region) per rfc-headless-quiescence.md
## Design 2. Black-box through fresco's public InlineScreen + MemorySink API.

{.experimental: "callOperator".}

import std/unittest
import fresco/inline_screen
import fresco/render/sink/memory

suite "B4: commitIdle":

  test "commitIdle true at rest on a fresh InlineScreen[MemorySink]":
    let s = newInlineScreen(newMemorySink(), 10, 40)
    check s.commitIdle()

  test "commitIdle false immediately after logSink.append (pendingCommit set synchronously, before the callSoon fires)":
    ## scheduleCommit sets s.pendingCommit = true synchronously, before the
    ## callSoon that drives the async batcher — so no await is needed to
    ## observe the flip. Also confirms surfaceIdle composes it: a pending
    ## commit alone (no dirty region) is enough to make surfaceIdle false.
    let s = newInlineScreen(newMemorySink(), 10, 40)
    check s.commitIdle()
    check s.surfaceIdle()
    s.logSink.append("line")
    check not s.commitIdle()
    check not s.surfaceIdle()

suite "B4: surfaceIdle composition":

  test "surfaceIdle false when a region is marked dirty while the commit batcher stays idle":
    ## markDirty touches only Region.pending (render/layout.nim), never the
    ## commit batcher flags — so this isolates surfaceIdle's second clause
    ## (anyPending(s.layout)) from its first (commitIdle).
    let s = newInlineScreen(newMemorySink(), 10, 40)
    let r = s.newRegion(1, 0, 9, 40)
    check s.commitIdle()
    check s.surfaceIdle()  # a freshly-allocated region starts non-pending
    r.markDirty()
    check s.commitIdle()      # unaffected by layout dirtiness
    check not s.surfaceIdle() # but the dirty region makes the surface non-idle
