## onRestart handler + lastWritesByLabel: scaffolding for state
## restoration across supervisor restarts.

{.experimental: "callOperator".}

import std/[unittest, tables, strutils]
import chronos
import intonaco/journal/events
import intonaco/journal/log
import intonaco/reactive

# Module-level types + restore overload for the #46 test. Has to live
# at module scope (not inside the test body) — Nim's `mixin` symbol
# resolution looks at module-level names, not nested procs.
type Color = enum cRed, cGreen, cBlue

proc `$`*(c: Color): string =
  case c
  of cRed: "red"
  of cGreen: "green"
  of cBlue: "blue"

proc restore*(s: string, _: typedesc[Color]): Color =
  case s
  of "red": cRed
  of "green": cGreen
  of "blue": cBlue
  else: raise newException(ValueError, "unknown color: " & s)

type Box = object
  width, height: int

proc `$`*(b: Box): string = $b.width & "x" & $b.height

suite "supervisor onRestart":

  setup:
    globalJournal = newJournal()

  test "onRestart fires before re-spawning, with previous taskId":
    proc body() {.async: (raises: [Exception]).} =
      var restartCallTids: seq[TaskId] = @[]
      var attempts = 0
      proc child(): Future[void] {.async.} =
        inc attempts
        await sleepAsync(1.milliseconds)
        if attempts < 3:
          raise newException(IOError, "again")

      let sup = newSupervisor(maxRestarts = 10, within = 1.seconds)
      sup.addChild("c", lcTransient, child,
        onRestart = proc(j: Journal, prev: TaskId) =
          restartCallTids.add prev)
      await sup.run()
      # 3 attempts → 2 restarts → 2 handler calls. Each prevTid is
      # the taskId of the previous (failed) child instance.
      check restartCallTids.len == 2
      check restartCallTids[0] != restartCallTids[1]
    waitFor body()

  test "lastWritesByLabel returns the most-recent state per signal":
    let t = TaskId.fresh()
    discard globalJournal.logTaskSpawned(t, NoEvent, "demo", "")
    discard globalJournal.logSignalWrite(t, NoEvent, "count", "1")
    discard globalJournal.logSignalWrite(t, NoEvent, "title", "hello")
    discard globalJournal.logSignalWrite(t, NoEvent, "count", "2")
    discard globalJournal.logSignalWrite(t, NoEvent, "count", "7")

    let table = globalJournal.lastWritesByLabel(t)
    check "count" in table
    check "title" in table
    check table["count"].writeRepr == "7"
    check table["title"].writeRepr == "hello"

  test "onRestart sees state writes from the previous task":
    proc body() {.async: (raises: [Exception]).} =
      var observedRepr: string = ""
      var attempts = 0
      proc child(): Future[void] {.async.} =
        inc attempts
        let count = signalC(0, label = "count")
        count.set(attempts * 10)        # journaled
        await sleepAsync(1.milliseconds)
        if attempts < 2:
          raise newException(IOError, "again")

      let sup = newSupervisor(maxRestarts = 10, within = 1.seconds)
      sup.addChild("c", lcTransient, child,
        onRestart = proc(j: Journal, prev: TaskId) =
          let last = j.lastWritesByLabel(prev)
          if "count" in last:
            observedRepr = last["count"].writeRepr)
      await sup.run()
      check observedRepr == "10"        # first attempt wrote 10 before failing
    waitFor body()

suite "supervisor orReplayJournal":

  setup:
    globalJournal = newJournal()

  test "orReplayJournal restores an int signal after restart":
    proc body() {.async: (raises: [Exception]).} =
      var attempts = 0
      var observedValues: seq[int] = @[]
      proc child(): Future[void] {.async.} =
        inc attempts
        let count = signalC(0, label = "count")
        observedValues.add count()       # what the new body sees at startup
        count.set(attempts * 100)        # journaled
        await sleepAsync(1.milliseconds)
        if attempts < 2:
          raise newException(IOError, "again")

      let sup = newSupervisor(maxRestarts = 5, within = 1.seconds)
      sup.addChild("c", lcTransient, child, onRestart = orReplayJournal)
      await sup.run()
      # First attempt: count starts at 0 (declared initial). Writes 100, crashes.
      # Restart: orReplayJournal stages count=100. Body's signalC(0, label="count")
      # consumes the staging → starts at 100.
      check observedValues == @[0, 100]
    waitFor body()

  test "restores float, bool, and string signals":
    proc body() {.async: (raises: [Exception]).} =
      var attempts = 0
      var sawF, sawS: string = ""
      var sawB: bool = false
      proc child(): Future[void] {.async.} =
        inc attempts
        let temperature = signalC(0.0, label = "temperature")
        let enabled = signalC(false, label = "enabled")
        let title = signalC("default", label = "title")
        if attempts == 2:
          sawF = $temperature()
          sawB = enabled()
          sawS = title()
        temperature.set(98.6)
        enabled.set(true)
        title.set("restored")
        await sleepAsync(1.milliseconds)
        if attempts < 2:
          raise newException(IOError, "again")

      let sup = newSupervisor(maxRestarts = 5, within = 1.seconds)
      sup.addChild("c", lcTransient, child, onRestart = orReplayJournal)
      await sup.run()
      check sawF == "98.6"
      check sawB == true
      check sawS == "restored"
    waitFor body()

  test "multiple labeled signals restored independently in same body":
    proc body() {.async: (raises: [Exception]).} =
      var attempts = 0
      var observed: seq[(int, int)] = @[]
      proc child(): Future[void] {.async.} =
        inc attempts
        let a = signalC(0, label = "a")
        let b = signalC(0, label = "b")
        observed.add (a(), b())
        a.set(attempts * 11)
        b.set(attempts * 22)
        await sleepAsync(1.milliseconds)
        if attempts < 2:
          raise newException(IOError, "again")

      let sup = newSupervisor(maxRestarts = 5, within = 1.seconds)
      sup.addChild("c", lcTransient, child, onRestart = orReplayJournal)
      await sup.run()
      check observed == @[(0, 0), (11, 22)]
    waitFor body()

  test "signal with label not in journal uses declared initial":
    proc body() {.async: (raises: [Exception]).} =
      var attempts = 0
      var observed = 0
      proc child(): Future[void] {.async.} =
        inc attempts
        let touched = signalC(0, label = "touched")
        let untouched = signalC(999, label = "untouched")  # never written
        observed = untouched()
        touched.set(attempts * 10)        # only this is journaled
        await sleepAsync(1.milliseconds)
        if attempts < 2:
          raise newException(IOError, "again")

      let sup = newSupervisor(maxRestarts = 5, within = 1.seconds)
      sup.addChild("c", lcTransient, child, onRestart = orReplayJournal)
      await sup.run()
      # `untouched` had no prior write, so restoration table doesn't
      # contain it. New instance uses declared initial (999).
      check observed == 999
    waitFor body()

  test "corrupt writeRepr falls back to declared initial":
    # Stage a deliberately-broken entry directly. The signal
    # constructor should warn and use the initial. The exact stderr
    # output isn't asserted (test framework would capture it).
    pendingRestoration = {"broken": "not-a-number"}.toTable
    let s = signalC(42, label = "broken")
    check s.peek() == 42                  # fallback used
    # Entry was consumed even on parse failure.
    check "broken" notin pendingRestoration

  test "unsupported type silently uses declared initial":
    # seq[int] is not in the {int,float,bool,string} set;
    # consumeRestoration's `else` branch returns fallback without
    # error.
    pendingRestoration = {"items": "1,2,3"}.toTable
    let s = signalC(@[7, 8, 9], label = "items")
    check s.peek() == @[7, 8, 9]
    check "items" notin pendingRestoration

  test "read-and-remove: two signals with same label, only first restored":
    pendingRestoration = {"shared": "100"}.toTable
    let first = signalC(0, label = "shared")
    let second = signalC(0, label = "shared")
    check first.peek() == 100
    check second.peek() == 0
    check "shared" notin pendingRestoration

  test "orReplayJournal on first spawn (no prior task) is a no-op":
    proc body() {.async: (raises: [Exception]).} =
      var observed = -1
      proc child(): Future[void] {.async.} =
        let count = signalC(7, label = "count")
        observed = count()
      let sup = newSupervisor()
      sup.addChild("c", lcTemporary, child, onRestart = orReplayJournal)
      await sup.run()
      # No prior task → no restoration. Declared initial used.
      check observed == 7
    waitFor body()

  test "pendingRestoration empty after body's synchronous setup consumes all":
    proc body() {.async: (raises: [Exception]).} =
      var attempts = 0
      var stagingEmpty = false
      proc child(): Future[void] {.async.} =
        inc attempts
        let count = signalC(0, label = "count")
        # Verify staging is empty IMMEDIATELY after construction.
        if attempts == 2:
          stagingEmpty = "count" notin pendingRestoration
        count.set(attempts * 5)
        await sleepAsync(1.milliseconds)
        if attempts < 2:
          raise newException(IOError, "again")
      let sup = newSupervisor(maxRestarts = 5, within = 1.seconds)
      sup.addChild("c", lcTransient, child, onRestart = orReplayJournal)
      await sup.run()
      check stagingEmpty
    waitFor body()

  test "successful restoration emits an ekSignalRestored journal event":
    proc body() {.async: (raises: [Exception]).} =
      var attempts = 0
      proc child(): Future[void] {.async.} =
        inc attempts
        let count = signalC(0, label = "count")
        count.set(attempts * 100)
        await sleepAsync(1.milliseconds)
        if attempts < 2:
          raise newException(IOError, "again")
      let sup = newSupervisor(maxRestarts = 5, within = 1.seconds)
      sup.addChild("c", lcTransient, child, onRestart = orReplayJournal)
      await sup.run()
      # Find the restoration audit event.
      var found = false
      for ev in globalJournal.events:
        if ev.kind == ekSignalRestored:
          check ev.restoredLabel == "count"
          check ev.restoredRepr == "100"
          found = true
      check found
    waitFor body()

  test "parse failure does not emit ekSignalRestored":
    pendingRestoration = {"broken": "not-a-number"}.toTable
    pendingRestorationSource = TaskId(0)
    let baselineCount = globalJournal.events.len
    let s = signalC(42, label = "broken")
    check s.peek() == 42       # fallback used (already covered)
    var restoredEventCount = 0
    for ev in globalJournal.events[baselineCount ..< globalJournal.events.len]:
      if ev.kind == ekSignalRestored: inc restoredEventCount
    check restoredEventCount == 0

  test "ekSignalRestored carries correct sourceTaskId, label, and repr":
    proc body() {.async: (raises: [Exception]).} =
      var attempts = 0
      var firstTaskId = TaskId(0)
      var secondTaskId = TaskId(0)
      proc child(): Future[void] {.async.} =
        inc attempts
        if attempts == 1:
          firstTaskId = currentScope.taskId
        else:
          secondTaskId = currentScope.taskId
        let count = signalC(0, label = "count")
        count.set(attempts * 7)
        await sleepAsync(1.milliseconds)
        if attempts < 2:
          raise newException(IOError, "again")
      let sup = newSupervisor(maxRestarts = 5, within = 1.seconds)
      sup.addChild("c", lcTransient, child, onRestart = orReplayJournal)
      await sup.run()
      var ev: Event
      var found = false
      for e in globalJournal.events:
        if e.kind == ekSignalRestored:
          ev = e
          found = true
          break
      check found
      check ev.taskId == secondTaskId          # new task
      check ev.restoredFromTaskId == firstTaskId   # prior task
      check ev.restoredLabel == "count"
      check ev.restoredRepr == "7"
    waitFor body()

  test "custom enum restored via user-defined `restore` overload":
    # Color + its `restore` overload are defined at module scope above.
    # The signal constructor's `when compiles(restore(repr, T))` picks
    # them up via the template's `mixin restore`.
    pendingRestoration = {"theme": "blue"}.toTable
    pendingRestorationSource = TaskId(0)
    let theme = signalC(cRed, label = "theme")
    check theme.peek() == cBlue
    check "theme" notin pendingRestoration

  test "custom type WITHOUT `restore` overload falls back silently":
    # `Box` is defined at module scope above but has no `restore`
    # overload; consumeRestoration falls through to the initial value.
    pendingRestoration = {"size": "10x20"}.toTable
    pendingRestorationSource = TaskId(0)
    let b = signalC(Box(width: 1, height: 1), label = "size")
    check b.peek() == Box(width: 1, height: 1)
    # Entry was still consumed (read-and-remove semantics).
    check "size" notin pendingRestoration

  test "filtered orReplayJournal stages only labels passing the predicate":
    proc body() {.async: (raises: [Exception]).} =
      var attempts = 0
      var seen = initTable[string, int]()
      proc child(): Future[void] {.async.} =
        inc attempts
        let kept = signalC(0, label = "ui.count")
        let dropped = signalC(0, label = "net.bytes")
        seen["ui.count"] = kept()
        seen["net.bytes"] = dropped()
        kept.set(attempts * 11)
        dropped.set(attempts * 99)
        await sleepAsync(1.milliseconds)
        if attempts < 2:
          raise newException(IOError, "again")
      let sup = newSupervisor(maxRestarts = 5, within = 1.seconds)
      # Only restore labels starting with "ui."
      sup.addChild("c", lcTransient, child,
                   onRestart = orReplayJournal(
                     proc(l: string): bool = l.startsWith("ui.")))
      await sup.run()
      # `ui.count` was filtered IN and restored → second-attempt sees 11.
      check seen["ui.count"] == 11
      # `net.bytes` was filtered OUT → second-attempt sees declared 0.
      check seen["net.bytes"] == 0
    waitFor body()
