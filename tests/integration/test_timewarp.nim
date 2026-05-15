## Time-warp + snapshot/compaction (#32 + #34).

import std/[unittest, tables, os, times]
import chronos
import fresco/journal/events
import fresco/journal/log
import fresco/journal/persist
import fresco/journal/timewarp
import fresco/reactive/scope
import fresco/reactive/signal

suite "timewarp: rewindTo + resumeLive":

  teardown:
    # rewindTo sets the rewinding flag; resumeLive clears it. Tests
    # that don't pair the two would otherwise leak `isRewinding() ==
    # true` into the next test, suppressing its journal writes.
    rewindingFlag = false

  test "rewindTo projects bound signal to its value at cutoff":
    # Tracer: a labeled Signal[int] writes 1, 2, 3 to the journal.
    # rewindTo(cutoff = event-id of write '2') sets the live signal
    # back to 2 via setUntracked (no new journal entry).
    let j = newJournal()
    globalJournal = j
    defer: globalJournal = nil

    discard createRoot:
      let s = signal(0, label = "count")
      bindForTimeWarp(s)
      s.set(1)
      s.set(2)
      let midId = j.events[^1].id
      s.set(3)
      check s.peek() == 3

      let evCountBefore = j.events.len
      rewindTo(j, midId)
      check s.peek() == 2
      # Projection must not journal new writes.
      check j.events.len == evCountBefore

  test "rewindTo re-fires observers with rewound value":
    let j = newJournal()
    globalJournal = j
    defer: globalJournal = nil
    discard createRoot:
      let s = signal(0, label = "cursor")
      bindForTimeWarp(s)
      s.set(10)
      let midId = j.events[^1].id
      s.set(20)
      s.set(30)
      var seen: seq[int] = @[]
      discard createRoot:
        createEffect proc() = seen.add s()
      # Effect first-run sees current value (30).
      check seen[^1] == 30
      rewindTo(j, midId)
      # Effect should have re-run with rewound value (10).
      check seen[^1] == 10

  test "resumeLive returns signal to head state and clears flag":
    let j = newJournal()
    globalJournal = j
    defer: globalJournal = nil
    discard createRoot:
      let s = signal(0, label = "n")
      bindForTimeWarp(s)
      s.set(1); s.set(2)
      let midId = j.events[^1].id
      s.set(3); s.set(4)
      rewindTo(j, midId)
      check s.peek() == 2
      check isRewinding()
      resumeLive(j)
      check s.peek() == 4
      check not isRewinding()

  test "unbound signal is not projected by rewindTo":
    let j = newJournal()
    globalJournal = j
    defer: globalJournal = nil
    discard createRoot:
      let bound = signal(0, label = "bound")
      let unbound = signal(0, label = "unbound")
      bindForTimeWarp(bound)
      # Note: `unbound` is NOT bound — its label is still journaled,
      # but no applier exists, so rewindTo doesn't touch it.
      bound.set(1); unbound.set(100)
      let midId = j.events[^1].id
      bound.set(2); unbound.set(200)
      rewindTo(j, midId)
      check bound.peek() == 1     # rewound
      check unbound.peek() == 200 # untouched — no binding

  test "side-effect writes during rewindTo don't append journal events":
    # Single-dispatcher invariant: rewindTo runs synchronously, so
    # nothing else can write to the journal "concurrently" in the
    # threading sense. The real failure mode is reentrant: an effect
    # re-fired by the rewind calls `s.set()` on some derived signal,
    # which would normally journal a fresh `ekSignalWrite`. That
    # would corrupt the historical trace mid-projection.
    #
    # Contract: while `isRewinding()` is true, `set` behaves like
    # `setUntracked` for journaling purposes — observers still see
    # the change, but no event is appended.
    let j = newJournal()
    globalJournal = j
    defer: globalJournal = nil
    discard createRoot:
      let s = signal(0, label = "n")
      let side = signal(0, label = "side")
      bindForTimeWarp(s)
      discard createRoot:
        createEffect proc() =
          side.set(s())
      s.set(1); s.set(2)
      let midId = j.events[^1].id
      s.set(3)
      let evCountBefore = j.events.len
      rewindTo(j, midId)
      # Effect re-fired and called side.set(2); that write must not
      # have appended a new journal event during the rewind.
      check j.events.len == evCountBefore

  test "user `restore` overload makes custom T time-warpable":
    type Color = enum cRed, cGreen, cBlue
    proc restore(s: string, _: typedesc[Color]): Color =
      case s
      of "cRed": cRed
      of "cGreen": cGreen
      of "cBlue": cBlue
      else: cRed
    let j = newJournal()
    globalJournal = j
    defer: globalJournal = nil
    discard createRoot:
      let c = signal(cRed, label = "color")
      bindForTimeWarp(c)
      c.set(cGreen)
      let midId = j.events[^1].id
      c.set(cBlue)
      rewindTo(j, midId)
      check c.peek() == cGreen

  test "binding is unregistered when its scope disposes":
    let j = newJournal()
    globalJournal = j
    defer: globalJournal = nil
    discard createRoot:
      let outerLive = signal(0, label = "outer")
      bindForTimeWarp(outerLive)
      outerLive.set(1)
      let root = createRoot:
        let inner = signal(0, label = "inner")
        bindForTimeWarp(inner)
        inner.set(10)
      let midId = j.events[^1].id
      outerLive.set(2)
      dispose(root)
      # After dispose, the "inner" applier is gone — rewindTo at midId
      # must not crash even though "inner" appears in stateAt(midId).
      rewindTo(j, midId)
      check outerLive.peek() == 1  # outer still rewound

suite "snapshot + compaction":

  test "snapshot captures current label state at head":
    let j = newJournal()
    let t = TaskId.fresh()
    discard j.logSignalWrite(t, NoEvent, "x", "1")
    discard j.logSignalWrite(t, NoEvent, "y", "100")
    discard j.logSignalWrite(t, NoEvent, "x", "2")
    let snap = j.snapshot()
    check snap.state["x"] == "2"
    check snap.state["y"] == "100"
    check snap.atEventId == j.events[^1].id

  test "compactBefore drops events but stateAt(headId) unchanged":
    let j = newJournal()
    let t = TaskId.fresh()
    discard j.logSignalWrite(t, NoEvent, "x", "1")
    discard j.logSignalWrite(t, NoEvent, "y", "100")
    let cutId = j.events[^1].id
    discard j.logSignalWrite(t, NoEvent, "x", "2")
    discard j.logSignalWrite(t, NoEvent, "y", "200")
    let headId = j.events[^1].id
    let stateBefore = j.stateAt(headId)
    j.compactBefore(cutId)
    let stateAfter = j.stateAt(headId)
    check stateBefore == stateAfter
    # Only post-cutoff events remain.
    check j.events.len == 2
    check j.base.atEventId == cutId
    check j.base.state["x"] == "1"
    check j.base.state["y"] == "100"

  test "stateAt below base.atEventId returns just the base snapshot":
    let j = newJournal()
    let t = TaskId.fresh()
    discard j.logSignalWrite(t, NoEvent, "x", "1")
    discard j.logSignalWrite(t, NoEvent, "x", "2")
    let cutId = j.events[^1].id
    discard j.logSignalWrite(t, NoEvent, "x", "3")
    j.compactBefore(cutId)
    # Query at an id below the compaction cutoff: granular history is
    # gone, only the base snapshot answers.
    let pre = j.stateAt(EventId(uint64(cutId) - 1))
    check pre["x"] == "2"   # base captured the last pre-cutoff write

  test "PersistentJournal: compactBefore round-trips through disk":
    let path = getTempDir() / ("fresco-compact-" & $getCurrentProcessId() & ".log")
    defer: discard tryRemoveFile(path)
    block:
      let j = openJournal(path)
      let t = TaskId.fresh()
      discard j.logSignalWrite(t, NoEvent, "x", "1")
      discard j.logSignalWrite(t, NoEvent, "y", "100")
      let cutId = j.events[^1].id
      discard j.logSignalWrite(t, NoEvent, "x", "2")
      j.compactBefore(cutId)
      close(j)
    # Reopen: base snapshot loads, remaining event replays.
    let j2 = openJournal(path)
    check j2.base.state["x"] == "1"
    check j2.base.state["y"] == "100"
    check j2.events.len == 1            # only the post-cutoff write
    let snap = j2.snapshot()
    check snap.state["x"] == "2"        # overlay applied
    check snap.state["y"] == "100"      # from base
    close(j2)
