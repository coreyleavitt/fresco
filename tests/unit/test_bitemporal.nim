import std/[unittest, tables, times]
import chronos
import fresco/journal/events
import fresco/journal/log

suite "bitemporal: eventsBefore + stateAt":

  test "eventsBefore returns prefix up to cutoff inclusive":
    let j = newJournal()
    let t = TaskId.fresh()
    let a = j.logTaskSpawned(t, NoEvent, "boot", "")
    let b = j.logSignalWrite(t, a, "x", "1")
    let c = j.logSignalWrite(t, b, "x", "2")
    let d = j.logTaskCompleted(t, c)
    check j.eventsBefore(a).len == 1
    check j.eventsBefore(b).len == 2
    check j.eventsBefore(c).len == 3
    check j.eventsBefore(d).len == 4

  test "stateAt returns last-known value per label up to cutoff":
    let j = newJournal()
    let t = TaskId.fresh()
    discard j.logTaskSpawned(t, NoEvent, "boot", "")
    discard j.logSignalWrite(t, NoEvent, "cursor", "0")
    discard j.logSignalWrite(t, NoEvent, "title",  "hello")
    let mid = j.logSignalWrite(t, NoEvent, "cursor", "5")
    discard j.logSignalWrite(t, NoEvent, "title",  "world")
    let final = j.logSignalWrite(t, NoEvent, "cursor", "9")

    # Scrub to mid: cursor was just set to 5, title still "hello".
    let snapMid = j.stateAt(mid, t)
    check snapMid["cursor"] == "5"
    check snapMid["title"]  == "hello"

    # Scrub to final: cursor=9, title=world.
    let snapFinal = j.stateAt(final, t)
    check snapFinal["cursor"] == "9"
    check snapFinal["title"]  == "world"

  test "stateAt with RootTask collects every task's writes":
    let j = newJournal()
    let tA = TaskId.fresh()
    let tB = TaskId.fresh()
    discard j.logSignalWrite(tA, NoEvent, "x", "1")
    let last = j.logSignalWrite(tB, NoEvent, "y", "2")
    let snap = j.stateAt(last)
    check "x" in snap and "y" in snap

  test "stateAt filtered by task ignores other tasks":
    let j = newJournal()
    let tA = TaskId.fresh()
    let tB = TaskId.fresh()
    discard j.logSignalWrite(tA, NoEvent, "x", "from-A")
    let last = j.logSignalWrite(tB, NoEvent, "x", "from-B")
    check j.stateAt(last, tA)["x"] == "from-A"
    check j.stateAt(last, tB)["x"] == "from-B"

  test "ancestors() walks gracefully across missing parent":
    # Regression for round-3 H3: ancestors used to crash with KeyError
    # when a loaded journal had gaps from schema-mismatch-skipped lines.
    let j = newJournal()
    let t = TaskId.fresh()
    let a = j.logTaskSpawned(t, NoEvent, "boot", "")
    # Simulate a gap: synthesize an event whose parentId points to a
    # non-existent id (as if the parent was skipped during load).
    let phantom = EventId(99_999_999'u)
    let b = j.logSignalWrite(t, phantom, "x", "1")  # parent missing
    let chain = j.ancestors(b)
    # Walk starts at b, fails to find phantom, stops gracefully.
    check chain.len == 1
    check chain[0].id == b

  test "empty-label writes are excluded from projection":
    # Regression for round-2 H3: every unlabeled signal used to share
    # the empty-string key, so restoration would clobber them with the
    # last-written value of *any* unlabeled signal. They're now
    # excluded from lastWritesByLabel / stateAt / stateAtTime entirely.
    let j = newJournal()
    let t = TaskId.fresh()
    discard j.logSignalWrite(t, NoEvent, "",      "unlabeled-a")
    discard j.logSignalWrite(t, NoEvent, "named", "value")
    let last = j.logSignalWrite(t, NoEvent, "",   "unlabeled-b")
    let snap = j.stateAt(last, t)
    check "" notin snap
    check snap["named"] == "value"
    let lwbl = j.lastWritesByLabel(t)
    check "" notin lwbl
    check "named" in lwbl

suite "bitemporal: eventsBetween (wall clock)":

  test "filters to events in [lo, hi]":
    let j = newJournal()
    let t = TaskId.fresh()
    let mid0 = getTime()
    discard j.logSignalWrite(t, NoEvent, "x", "before")
    let cut = getTime()
    discard j.logSignalWrite(t, NoEvent, "x", "after")
    let later = getTime()
    let inRange = j.eventsBetween(mid0, cut)
    # Some events fall in [mid0, cut]; the one written after `cut`
    # should be excluded.
    var seenBefore = false
    var seenAfter = false
    for e in inRange:
      if e.writeRepr == "before": seenBefore = true
      if e.writeRepr == "after":  seenAfter = true
    check seenBefore
    check not seenAfter
    # Sanity: extend range to `later` and "after" reappears.
    let widerInRange = j.eventsBetween(mid0, later)
    var anyAfter = false
    for e in widerInRange:
      if e.writeRepr == "after": anyAfter = true
    check anyAfter
