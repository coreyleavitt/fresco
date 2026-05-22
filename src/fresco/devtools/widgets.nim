## Devtools panel widgets — pure rendering functions.
##
## Each widget converts a domain snapshot (topology, journal event,
## ancestor chain, scrubber state) into a `seq[string]` of display
## lines. No I/O, no scope dependency, no Region writes — the
## integrating panel composes these onto regions via the existing
## `bindRows` / `bindCollection` machinery.
##
## Keeping the rendering pure pays back in two places: (1) the
## widgets are trivially unit-testable, and (2) the integration
## layer doesn't have to mock terminal state to verify widget
## behavior, only string output.

import std/strutils
import intonaco/task/supervisor
import intonaco/journal/events
import intonaco/journal/log
import ../events as input

proc renderTaskTree*(topo: openArray[TopologyNode]): seq[string] =
  ## Render a supervisor topology snapshot as one line per node.
  ## Pool summary nodes get a header line; pool members are indented
  ## under their parent pool. Named children appear flat.
  ##
  ## Format:
  ##   <symbol> <name> [lifecycle] (running|stopped) restarts=<n>
  ##
  ## Symbol: `*` for named children, `▸` for pools, `└` for pool members.
  for node in topo:
    let symbol =
      case node.kind
      of nkChild:      "*"
      of nkPool:       "▸"
      of nkPoolMember: " └"
    let state = if node.running: "running" else: "stopped"
    var line = symbol & " " & node.name & " [" & $node.lifecycle & "] " & state
    if node.restartCount > 0:
      line &= " restarts=" & $node.restartCount
    if node.kind == nkPool:
      line &= " (" & $node.poolSize & "/" & $node.poolMax & ")"
    result.add line

proc renderEvent*(e: Event): string =
  ## Render a single journal event as one display line. Keep the
  ## format compact — devtools streams thousands of these in a
  ## tail-window region. Format:
  ##
  ##   #<id> [<task>] <kind> <payload>
  ##
  ## Payload varies by kind. Long writeReprs are not truncated here —
  ## the caller's region width does that via the line-clip path.
  let prefix = "#" & $uint64(e.id) & " [t" & $uint32(e.taskId) & "] "
  case e.kind
  of ekTaskSpawned:
    prefix & "spawned " & e.spawnedName
  of ekTaskCompleted:
    prefix & "completed"
  of ekTaskCancelled:
    prefix & "cancelled: " & e.cancelReason
  of ekTaskFailed:
    prefix & "failed: " & e.failureType & ": " & e.failureMsg
  of ekSignalWrite:
    prefix & "write " & e.signalLabel & "=" & e.writeRepr
  of ekSignalRestored:
    prefix & "restored " & e.restoredLabel & "=" & e.restoredRepr
  of ekCollectionDelta:
    prefix & e.collectionOp & " " & e.collectionLabel &
            "[" & $e.collectionIdx & "]=" & e.collectionRepr
  of ekCollectionRollback:
    prefix & "rollback " & e.rollbackLabel & " ×" & $e.rollbackCount
  of ekKeyReceived:
    prefix & "key " & e.keySummary
  of ekKeyConsumed:
    prefix & "key consumed " & e.keySummary
  of ekSupervisorRestart:
    prefix & "restart " & e.restartName & " gen=" & $e.generation
  of ekSupervisorEscalate:
    prefix & "escalate " & e.escalateName & ": " & e.escalateReason
  of ekSupervisorTerminate:
    prefix & "terminate " & e.terminateName

type
  ScrubberState* = object
    ## State of the time-warp scrubber widget. Owned by the panel
    ## task; mutated in place by `scrubStep`. `cursor` is an index
    ## into the journal's event list (0-based). `total` is the
    ## journal's event count at the time scrubbing began — the panel
    ## is responsible for keeping it in sync as new events arrive
    ## (typically: total = j.events.len, refreshed on each tick).
    ## `active` is false when the scrubber is sitting in "live mode"
    ## (no rewindTo in effect); a directional key in live mode is
    ## what engages it.
    cursor*: int
    total*: int
    active*: bool

  ScrubAction* = enum
    saNone     ## key didn't move the scrubber (e.g., unrelated key)
    saRewind   ## cursor moved; panel should call `rewindTo(j, eventAtCursor)`
    saResume   ## escape pressed; panel should call `resumeLive(j)`

proc scrubStep*(s: var ScrubberState, ev: KeyEvent): ScrubAction =
  ## Apply one key event to the scrubber state. Returns the action
  ## the panel should perform: rewind (re-project signals to the
  ## new cursor), resume (return to live), or none.
  ##
  ## Engagement: from inactive state, the first arrow key engages
  ## scrub mode AND moves. Escape disengages.
  ##
  ## Boundary clamping: cursor is held in `[0, total-1]`. If the
  ## journal is empty (total == 0), every key is a no-op.
  if s.total <= 0: return saNone
  case ev.kind
  of kArrowLeft:
    if not s.active:
      s.active = true
      s.cursor = max(0, s.total - 1)
    if s.cursor > 0: dec s.cursor
    saRewind
  of kArrowRight:
    if not s.active:
      s.active = true
      s.cursor = max(0, s.total - 1)
    if s.cursor < s.total - 1: inc s.cursor
    saRewind
  of kEscape:
    if s.active:
      s.active = false
      saResume
    else:
      saNone
  else:
    saNone

proc renderScrubber*(cursor, total, width: int): string =
  ## Single-line progress-bar rendering of scrubber state. `width`
  ## is the inner bar width (excluding brackets and "n/m" suffix).
  ## Example output: `[==========    ] 70/100`
  if total <= 0:
    return "[" & repeat(' ', max(0, width)) & "] 0/0"
  let filled = if total <= 1: width else: (cursor * width) div (total - 1)
  let bar = repeat('=', filled) & repeat(' ', max(0, width - filled))
  "[" & bar & "] " & $cursor & "/" & $total

proc renderCausalChain*(j: Journal, id: EventId): seq[string] =
  ## Render the chain of events from `id` back through `parentId`
  ## links to the causal root. Innermost (selected) event on top;
  ## each step back is indented one space so depth is visible at a
  ## glance. Used by the devtools "inspect" action — selecting an
  ## event opens this view to its right or below.
  let chain = j.ancestors(id)
  for i, ev in chain:
    result.add repeat(' ', i) & renderEvent(ev)
