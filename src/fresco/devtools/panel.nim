## Devtools panel composition.
##
## The full panel — alt-screen layout + key routing + reactive
## bindings — would normally live in a fresco app, dogfooding the
## DSL. This module exposes the **testable kernel** of the panel:
## a `PanelState` value, a `handleKey` proc that mutates it in
## response to keystrokes, and the projection actions the panel
## should perform on the journal.
##
## Integration code (the example app in `examples/`) wraps this
## kernel with the `region:`/`bindRows`/`receive:` DSL machinery to
## get a real running devtools panel. The widgets in `widgets.nim`
## handle the per-frame rendering.

import std/unicode
import chronos
import ./widgets
import ../events as input
import ../input as inputs
import ../journal/events
import ../journal/log
import ../journal/timewarp
import ../reactive/scope
import ../reactive/signal
import ../reactive/binding
import ../reactive/collection
import ../task/supervisor
import ../screen

type
  PanelState* = ref object
    ## Mutable state owned by the panel task. Held as a ref so the
    ## handler and the rendering effects share a single instance.
    scrubber*: ScrubberState
    selectedEvent*: EventId
      ## Event currently displayed in the causal-chain inspector.
      ## NoEvent when nothing is selected.

proc newPanelState*(j: Journal): PanelState =
  ## Construct a fresh panel state for the given journal. `scrubber`
  ## starts in inactive (live) mode at the journal's head.
  result = PanelState(
    scrubber: ScrubberState(
      cursor: max(0, j.events.len - 1),
      total: j.events.len,
      active: false),
    selectedEvent: NoEvent)

proc handleKey*(state: PanelState, ev: KeyEvent, j: Journal): bool =
  ## Apply one key event to the panel state. Returns true if the
  ## panel should keep running, false to exit (handled by the
  ## panel's main loop, which on false will tear down the alt-screen
  ## and return).
  ##
  ## Side effects on the journal (rewindTo / resumeLive) happen here
  ## so the caller doesn't have to coordinate between scrubber state
  ## and journal projection. This keeps the integration layer free
  ## of any "did scrubber change → call rewindTo" plumbing.
  case ev.kind
  of kChar:
    if $ev.rune == "q": return false
    return true
  of kArrowLeft, kArrowRight, kEscape:
    # Always refresh `total` before stepping so the scrubber knows
    # the current journal length (new events may have arrived since
    # the panel last refreshed).
    state.scrubber.total = j.events.len
    case scrubStep(state.scrubber, ev)
    of saRewind:
      if state.scrubber.cursor >= 0 and
         state.scrubber.cursor < j.events.len:
        rewindTo(j, j.events[state.scrubber.cursor].id)
    of saResume:
      resumeLive(j)
    of saNone:
      discard
    return true
  of kEnter:
    # Select the event at the scrubber cursor for causal inspection.
    if state.scrubber.cursor >= 0 and
       state.scrubber.cursor < j.events.len:
      state.selectedEvent = j.events[state.scrubber.cursor].id
    return true
  else:
    return true

proc snapshotTopology(supervisors: openArray[Supervisor]): seq[TopologyNode] =
  for s in supervisors:
    for n in s.topology(): result.add n

proc runDevtoolsPanel*(j: Journal, supervisors: seq[Supervisor],
                      stream: InputStream, screen: Screen)
                      {.async: (raises: [Exception]).} =
  ## Compose the devtools widgets into a running panel against
  ## `screen`. Three vertical regions: task tree (top third),
  ## journal stream (middle third, tail-window via wmFromEnd),
  ## scrubber (bottom third). `q` exits; ←/→ scrub; Escape resumes
  ## live; Enter pins the cursor's event for causal inspection.
  ##
  ## Polling: topology and the journal stream sync once per key
  ## event. For a more responsive panel, add a chronos timer that
  ## fires every ~100ms and re-syncs — out of scope for the C1 cut
  ## (the panel reacts to user input in real time; passive updates
  ## are visible on the next keystroke).
  # cast(gcsafe): fresco is single-dispatcher; bindCollection isn't
  # statically proven gcsafe because of its closure-capturing
  # handler, but no concurrent thread touches our refs. Matches the
  # pattern used in persist.nim, animation.nim, and timewarp.nim
  # for the same reason.
  {.cast(gcsafe).}:
    let root = newScope()
    try:
      withScope(root):
        let topo   = signal(snapshotTopology(supervisors))
        let events = collection[Event](@[])
        for e in j.events: events.push(e)
        let state = newPanelState(j)

        let h = screen.height
        let thirds = max(1, h div 3)
        let treeR   = newRegion(screen, 0,            0, thirds, screen.width)
        let streamR = newRegion(screen, thirds,       0, thirds, screen.width)
        let scrubR  = newRegion(screen, 2 * thirds,   0,
                                max(1, h - 2 * thirds), screen.width)

        bindRows treeR, 0 ..< treeR.height: renderTaskTree(topo())
        bindCollection(streamR, 0 ..< streamR.height, events,
                       proc(e: Event): string = renderEvent(e),
                       mode = wmFromEnd)
        bindRow scrubR, 0:
          renderScrubber(state.scrubber.cursor, state.scrubber.total,
                         max(4, scrubR.width - 16))
        paint(screen)

        while true:
          let key = await stream.nextKey()
          while events.len < j.events.len:
            events.push(j.events[events.len])
          topo.set(snapshotTopology(supervisors))
          if not handleKey(state, key, j):
            paint(screen)
            return
          paint(screen)
    finally:
      dispose(root)
