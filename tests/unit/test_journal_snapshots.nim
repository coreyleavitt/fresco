## Multi-tier snapshot history (#49).

import std/[os, tables, unittest]
import fresco/journal/events
import fresco/journal/log
import fresco/journal/persist

suite "journal: multi-snapshot foundation":

  test "addSnapshot captures current head state":
    let j = newJournal()
    let t = TaskId.fresh()
    discard j.logSignalWrite(t, NoEvent, "x", "1")
    discard j.logSignalWrite(t, NoEvent, "y", "100")
    let snap = j.addSnapshot()
    check snap.state["x"] == "1"
    check snap.state["y"] == "100"
    check snap.atEventId == j.events[^1].id
    check j.snapshots.len == 1

  test "stateAt between two snapshots seeds from the nearest ≤ cutoff":
    # The consumer-facing win: with snapshots scattered through
    # history, stateAt(midpoint) doesn't have to walk every event
    # from time 0 — it starts at the nearest snapshot and replays
    # forward.
    let j = newJournal()
    let t = TaskId.fresh()
    discard j.logSignalWrite(t, NoEvent, "x", "1")
    let snap1 = j.addSnapshot()               # snapshot @ id1: x=1
    discard j.logSignalWrite(t, NoEvent, "x", "2")
    discard j.logSignalWrite(t, NoEvent, "y", "99")
    let midId = j.events[^1].id               # cutoff lands in the middle
    discard j.logSignalWrite(t, NoEvent, "x", "3")
    discard j.addSnapshot()                   # snapshot @ tail: x=3
    discard j.logSignalWrite(t, NoEvent, "x", "4")
    let s = j.stateAt(midId)
    check s["x"] == "2"     # last write at or before midId
    check s["y"] == "99"
    check uint64(snap1.atEventId) < uint64(midId)   # sanity — seeded from snap1

  test "stateAt below earliest snapshot returns earliest snapshot's state":
    let j = newJournal()
    let t = TaskId.fresh()
    discard j.logSignalWrite(t, NoEvent, "x", "1")
    discard j.logSignalWrite(t, NoEvent, "x", "2")
    discard j.addSnapshot()                   # earliest snapshot @ x=2
    discard j.logSignalWrite(t, NoEvent, "x", "3")
    # Query a cutoff BELOW the earliest snapshot's atEventId.
    let belowEarliest = EventId(uint64(j.snapshots[0].atEventId) - 1)
    let s = j.stateAt(belowEarliest)
    check s["x"] == "2"     # graceful: earliest snapshot

  test "addSnapshot at same head is idempotent":
    let j = newJournal()
    let t = TaskId.fresh()
    discard j.logSignalWrite(t, NoEvent, "x", "1")
    let s1 = j.addSnapshot()
    let s2 = j.addSnapshot()
    check j.snapshots.len == 1
    check s1.atEventId == s2.atEventId

suite "journal: compaction primitives":

  test "compactBefore drops events and collapses pre-cutoff snapshots into one base":
    let j = newJournal()
    let t = TaskId.fresh()
    discard j.logSignalWrite(t, NoEvent, "x", "1")
    discard j.addSnapshot()                   # snap @ x=1
    discard j.logSignalWrite(t, NoEvent, "x", "2")
    discard j.addSnapshot()                   # snap @ x=2
    let cutId = j.events[^1].id
    discard j.logSignalWrite(t, NoEvent, "x", "3")
    discard j.addSnapshot()                   # snap @ x=3 (post-cutoff)
    j.compactBefore(cutId)
    # Pre-cutoff snapshots collapsed into one base; post-cutoff preserved.
    check j.snapshots.len == 2                # base + post-cutoff snap
    check j.snapshots[0].atEventId == cutId
    check j.snapshots[0].state["x"] == "2"
    check j.snapshots[1].state["x"] == "3"
    check j.events.len == 1                   # the post-cutoff event survives

  test "promoteBefore drops events but preserves pre-cutoff snapshots":
    let j = newJournal()
    let t = TaskId.fresh()
    discard j.logSignalWrite(t, NoEvent, "x", "1")
    let snap1 = j.addSnapshot()               # snap @ x=1
    discard j.logSignalWrite(t, NoEvent, "x", "2")
    let snap2 = j.addSnapshot()               # snap @ x=2
    let cutId = j.events[^1].id
    discard j.logSignalWrite(t, NoEvent, "x", "3")
    j.promoteBefore(cutId)
    # Both pre-cutoff snapshots preserved (key distinguishing feature
    # from compactBefore).
    check j.snapshots.len == 2
    check j.snapshots[0].atEventId == snap1.atEventId
    check j.snapshots[1].atEventId == snap2.atEventId
    # Events ≤ cutoff dropped.
    for ev in j.events:
      check uint64(ev.id) > uint64(cutId)
    # stateAt at snap1's id still routes through snap1 (multi-snapshot
    # projection precision survives promotion).
    let s = j.stateAt(snap1.atEventId)
    check s["x"] == "1"

  test "coarsen drops snapshots per keepEvery in a range":
    let j = newJournal()
    let t = TaskId.fresh()
    for i in 1 .. 6:
      discard j.logSignalWrite(t, NoEvent, "n", $i)
      discard j.addSnapshot()
    check j.snapshots.len == 6
    let loId = j.snapshots[0].atEventId
    let hiId = j.snapshots[^1].atEventId
    j.coarsen(loId .. hiId, keepEvery = 2)
    # 6 snapshots in range, keepEvery=2 → keep indices 0,2,4 → 3 snapshots.
    check j.snapshots.len == 3

suite "journal: retention policy (the ladder)":

  test "applyRetention auto-snapshots when events count >= snapshotEvery":
    let j = newJournal()
    let t = TaskId.fresh()
    let policy = RetentionPolicy(snapshotEvery: 3,
                                 keepEvents: 1_000_000,
                                 coarsenAfter: 1_000_000)
    for i in 1 .. 6:
      discard j.logSignalWrite(t, NoEvent, "n", $i)
      j.applyRetention(policy)
    # After 6 events with snapshotEvery=3: snapshots taken at events
    # 3 and 6 (two snapshots total).
    check j.snapshots.len == 2

  test "applyRetention promotes (drops events) when count > keepEvents":
    let j = newJournal()
    let t = TaskId.fresh()
    let policy = RetentionPolicy(snapshotEvery: 1_000_000,
                                 keepEvents: 5,
                                 coarsenAfter: 1_000_000)
    for i in 1 .. 10:
      discard j.logSignalWrite(t, NoEvent, "n", $i)
    j.applyRetention(policy)
    # keepEvents=5, head event is id=10, so events with id ≤ 5 dropped.
    check j.events.len == 5
    # A floor snapshot was synthesized so post-promotion stateAt still
    # works at the boundary.
    check j.snapshots.len >= 1
    let s = j.stateAt(j.events[^1].id)
    check s["n"] == "10"

  test "applyRetention coarsens older snapshots when count > coarsenAfter":
    let j = newJournal()
    let t = TaskId.fresh()
    # Pre-populate many snapshots manually.
    for i in 1 .. 10:
      discard j.logSignalWrite(t, NoEvent, "n", $i)
      discard j.addSnapshot()
    check j.snapshots.len == 10
    let policy = RetentionPolicy(snapshotEvery: 1_000_000,
                                 keepEvents: 1_000_000,
                                 coarsenAfter: 6)
    j.applyRetention(policy)
    # Older half coarsened by 2 (every other dropped); the half boundary
    # is at index 5 (zero-based; 10/2). Snapshots 0..4 coarsen → keep
    # indices 0,2,4 → 3; snapshots 5..9 untouched → 5; total 8.
    check j.snapshots.len == 8

suite "journal: persistent multi-snapshot round-trip":

  test "multiple snapshots serialized + restored in order":
    let path = getTempDir() / ("fresco-multisnap-" &
                               $getCurrentProcessId() & ".log")
    defer: discard tryRemoveFile(path)
    block:
      let j = openJournal(path)
      let t = TaskId.fresh()
      discard j.logSignalWrite(t, NoEvent, "x", "1")
      discard j.addSnapshot()                # snap1 @ x=1
      discard j.logSignalWrite(t, NoEvent, "x", "2")
      discard j.addSnapshot()                # snap2 @ x=2
      let midId = j.events[^1].id
      discard j.logSignalWrite(t, NoEvent, "x", "3")
      # Compact to test that the rewrite emits multiple snapshot frames.
      j.compactBefore(midId)
      # Pre-compact: 2 snapshots. compactBefore collapses to 1 base +
      # any post-cutoff snapshots. Here both pre-cutoff snaps collapse
      # to one base; no post-cutoff snaps existed.
      check j.snapshots.len == 1
      # Add a fresh snapshot after the post-cutoff event.
      discard j.addSnapshot()
      check j.snapshots.len == 2
      close(j)
    # Reopen and verify both snapshots restored in order.
    let j2 = openJournal(path)
    check j2.snapshots.len == 2
    check uint64(j2.snapshots[0].atEventId) < uint64(j2.snapshots[1].atEventId)
    close(j2)
