## Devtools panel widgets (#36).
##
## Unit tests for the pure rendering functions. The integrated
## panel (alt-screen, hotkey routing, region layout) gets a smoke
## test via the example app — these tests cover the testable
## decisions: how topology / events / ancestors / scrubber state
## get converted to display lines.

import std/[strutils, unicode, unittest, times]
import fresco/devtools/widgets
import fresco/devtools/panel
import fresco/reactive/scope
import fresco/reactive/signal
import fresco/task/supervisor
import fresco/journal/events
import fresco/journal/log
import fresco/journal/timewarp
import fresco/events as input

suite "devtools widgets: task tree":

  test "renders a flat list of named children":
    let topo = @[
      TopologyNode(kind: nkChild, name: "agent",
                   lifecycle: lcTransient, running: true, restartCount: 0),
      TopologyNode(kind: nkChild, name: "ui",
                   lifecycle: lcPermanent, running: true, restartCount: 2),
    ]
    let lines = renderTaskTree(topo)
    check lines.len == 2
    check "agent" in lines[0]
    check "ui" in lines[1]
    # Restart count is surfaced for operators inspecting recovery behavior.
    check "2" in lines[1]

  test "renders pool members under their pool summary":
    let topo = @[
      TopologyNode(kind: nkPool, name: "workers",
                   lifecycle: lcTransient, running: true,
                   poolSize: 2, poolMax: 4),
      TopologyNode(kind: nkPoolMember, name: "workers#1",
                   lifecycle: lcTransient, running: true),
      TopologyNode(kind: nkPoolMember, name: "workers#2",
                   lifecycle: lcTransient, running: true),
    ]
    let lines = renderTaskTree(topo)
    check lines.len == 3
    check "workers" in lines[0]
    check "2/4" in lines[0]                     # pool size summary
    check lines[1].startsWith(" └")             # member indent symbol
    check "workers#1" in lines[1]

suite "devtools widgets: journal event":

  test "renders a signal write as label=value line":
    let e = Event(kind: ekSignalWrite, id: EventId(42),
                  taskId: TaskId(1), parentId: EventId(0),
                  signalLabel: "count", writeRepr: "7")
    let line = renderEvent(e)
    check "count" in line
    check "7" in line
    check "42" in line     # event id

  test "renders a task spawn":
    let e = Event(kind: ekTaskSpawned, id: EventId(5),
                  taskId: TaskId(2), parentId: EventId(0),
                  spawnedName: "agent", spawnedType: "")
    let line = renderEvent(e)
    check "spawn" in line.toLowerAscii or "spawned" in line.toLowerAscii
    check "agent" in line

suite "devtools widgets: causal chain":

  test "renders the ancestor chain innermost-first":
    let j = newJournal()
    let t = TaskId.fresh()
    let a = j.logTaskSpawned(t, NoEvent, "boot", "")
    let b = j.logSignalWrite(t, a, "x", "1")
    let c = j.logSignalWrite(t, b, "x", "2")
    let lines = renderCausalChain(j, c)
    check lines.len == 3
    # First line is the innermost event (`c`), last is the root (`a`).
    check "#" & $uint64(c) in lines[0]
    check "#" & $uint64(b) in lines[1]
    check "#" & $uint64(a) in lines[2]
    # Indentation grows for each step back, so a glance shows depth.
    check lines[1].startsWith(" ")
    check lines[2].startsWith("  ")

suite "devtools widgets: scrubber":

  test "renderScrubber draws a progress bar with position + total":
    let line = renderScrubber(cursor = 3, total = 10, width = 12)
    # Format: "[bar] cursor/total"
    check "3/10" in line
    check "[" in line and "]" in line

  test "scrubStep on ArrowRight advances cursor and emits saRewind":
    var s = ScrubberState(cursor: 5, total: 10, active: true)
    let action = scrubStep(s, atomKey(kArrowRight))
    check s.cursor == 6
    check action == saRewind

  test "scrubStep on ArrowLeft retreats cursor":
    var s = ScrubberState(cursor: 5, total: 10, active: true)
    let action = scrubStep(s, atomKey(kArrowLeft))
    check s.cursor == 4
    check action == saRewind

  test "scrubStep clamps at boundaries":
    var s = ScrubberState(cursor: 0, total: 10, active: true)
    discard scrubStep(s, atomKey(kArrowLeft))
    check s.cursor == 0                    # clamped at 0
    var s2 = ScrubberState(cursor: 9, total: 10, active: true)
    discard scrubStep(s2, atomKey(kArrowRight))
    check s2.cursor == 9                   # clamped at total-1

  test "scrubStep on Escape resumes live and emits saResume":
    var s = ScrubberState(cursor: 3, total: 10, active: true)
    let action = scrubStep(s, atomKey(kEscape))
    check action == saResume
    check not s.active

  test "scrubStep first ArrowRight from live engages scrub mode":
    var s = ScrubberState(cursor: 9, total: 10, active: false)
    let action = scrubStep(s, atomKey(kArrowLeft))
    check s.active
    check s.cursor == 8
    check action == saRewind

suite "devtools panel: key routing":

  test "'q' returns false → panel main-loop exits":
    let j = newJournal()
    var state = newPanelState(j)
    let keepRunning = handleKey(state, charKey(Rune('q')), j)
    check not keepRunning

  test "non-quit keys keep panel running":
    let j = newJournal()
    var state = newPanelState(j)
    check handleKey(state, charKey(Rune('x')), j)
    check handleKey(state, atomKey(kEnter), j)

  test "ArrowLeft engages scrubber and triggers rewindTo":
    let j = newJournal()
    globalJournal = j
    defer: globalJournal = nil
    let t = TaskId.fresh()
    discard createRoot:
      let cur = signal(0, label = "cur")
      bindForTimeWarp(cur)
      cur.set(1)
      cur.set(2)
      cur.set(3)
      var state = newPanelState(j)
      state.scrubber.total = j.events.len
      check handleKey(state, atomKey(kArrowLeft), j)
      check state.scrubber.active
      # After at least one rewindTo: isRewinding should be true.
      check isRewinding()
      # Reset for clean teardown.
      resumeLive(j)

  test "Escape resumes live mode":
    let j = newJournal()
    let t = TaskId.fresh()
    for i in 0 ..< 5:
      discard j.logSignalWrite(t, NoEvent, "x", $i)
    var state = newPanelState(j)
    state.scrubber.active = true
    state.scrubber.cursor = 2
    check handleKey(state, atomKey(kEscape), j)
    check not state.scrubber.active
    check not isRewinding()
