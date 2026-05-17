# Nim runtime patches

Standalone unified-diff artifacts targeting Nim's runtime, headed for
upstream submission. **None of these are fresco build dependencies** —
fresco runs cleanly on stock Nim 2.x.

## `nim-cycle-destroy-reentry.patch`

A real Nim 2.x ARC/ORC defect: when destroying a cell that participates
in a reference cycle, a back-edge decref inside the destructor's body
can satisfy the rc-zero check again on the same cell and trigger a
recursive destroy. Symptom: stack overflow inside
`nimDestroyAndDispose` recursing through `nimDecRefIsLastCyclicStatic`.

Minimal standalone repro (30 lines, no third-party deps) is in the
patch header. The fix is a re-entry guard via a high-bit `destroyingFlag`
on the rc word, honored by all four decref entry points
(`nimDecRefIsLast`, `nimDecRefIsLast{,Cyclic}Dyn`,
`nimDecRefIsLastCyclicStatic`) plus a two-phase free in
`collectCyclesBacon` (destruct all in toFree before deallocating any —
prevents back-edge UAF when one cell's destructor decrefs a cell
already deallocated earlier in the loop).

### Why fresco doesn't need this

fresco's reactive substrate has a `Subscribable ↔ Computation` cycle
on paper (`s.observers` holds `Computation` refs; `c.sources` holds
`Subscribable` refs back). But the cycle is always broken on scope
disposal: `unsubscribeAll(c)` runs from the cleanup closure and clears
both `c.sources` and the corresponding `s.observers` entries before
any ARC/ORC destruction fires. The defective destructor recursion
path therefore isn't reached from normal fresco usage.

The Nim bug is independently real, and the patch is worth submitting
upstream so other Nim users with similar shapes don't hit it. But
it's not load-bearing for fresco.

## Applying

```
cd $NIM_HOME && patch -p1 < /path/to/nim-cycle-destroy-reentry.patch
```

(Where `$NIM_HOME` is the directory containing `lib/system/`.)
