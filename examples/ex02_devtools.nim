## Minimal devtools panel — observes the global journal in real time
## and prints each event as it arrives. Demonstrates the introspection
## surface v2.4 exposes:
##
##   - globalJournal carries every state mutation, task lifecycle
##     transition, supervisor decision, and key dispatch.
##   - byKind / byTask / lastWritesByLabel / stateAt are the queries
##     a real devtools panel uses.
##
## Visual check: spawn some demo tasks; watch the journal scroll past
## with TaskSpawned / StateWrite / TaskCompleted events.

import std/strformat
import chronos
import fresco
import fresco/reactive/signal

proc demoWorker(id: int) {.async.} =
  signals:
    count = 0
  for i in 1 .. 5:
    count := i
    await sleepAsync(80.milliseconds)

proc main() {.async: (raises: [Exception]).} =
  globalJournal = newJournal()
  let sup = newSupervisor()
  sup.addChild("workerA", lcTemporary, proc(): Future[void] = demoWorker(1))
  sup.addChild("workerB", lcTemporary, proc(): Future[void] = demoWorker(2))

  let m = spawn sup.run()

  # Print events as they're appended. Polling is a teaching simplification;
  # a real devtools panel would subscribe to a change signal on the
  # journal length or render reactively.
  var lastSeen = 0
  for _ in 0 .. 30:
    while lastSeen < globalJournal.len:
      let e = globalJournal[lastSeen]
      var summary = $e.kind & " task=" & $e.taskId
      case e.kind
      of ekSignalWrite:
        summary &= " " & e.signalLabel & "=" & e.writeRepr
      of ekTaskSpawned:
        summary &= " " & e.spawnedName
      of ekSupervisorRestart, ekSupervisorTerminate, ekSupervisorEscalate:
        summary &= " " & (if e.kind == ekSupervisorRestart: e.restartName
                          elif e.kind == ekSupervisorTerminate: e.terminateName
                          else: e.escalateName)
      else: discard
      stderr.writeLine fmt"[{e.id}] {summary}"
      inc lastSeen
    if m.future.finished: break
    await sleepAsync(40.milliseconds)

  let snap = sup.topology()
  stderr.writeLine ""
  stderr.writeLine "topology after run:"
  if snap.len == 0:
    stderr.writeLine "  (all children completed)"
  for n in snap:
    stderr.writeLine fmt"  {n.name} lifecycle={n.lifecycle} running={n.running} restarts={n.restartCount}"

waitFor main()
