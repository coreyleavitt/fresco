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
import intonaco/journal/events
import intonaco/journal/log
# timewarp lives inside intonaco/reactive as substrate-author code
import intonaco/reactive
import ../reactive/binding
import ../screen
import ../render/sink

type
  PanelState* = ref object
    ## Mutable state owned by the panel task. Held as a ref so the
    ## handler and the rendering effects share a single instance.
    ##
    ## `scrubber` is a Signal so widget bindings that depend on it
    ## (the scrubber row in `runDevtoolsPanel`) re-render on each
    ## ←/→/Escape. Pre-F-M2 it was a plain field — bindings observed
    ## stale values because the input loop mutated in place under a
    ## binding with no declared dep.
    scrubber*: Signal[ScrubberState]
    selectedEvent*: EventId
      ## Event currently displayed in the causal-chain inspector.
      ## NoEvent when nothing is selected.

proc newPanelState*(j: Journal): PanelState =
  ## Construct a fresh panel state for the given journal. `scrubber`
  ## starts in inactive (live) mode at the journal's head.
  result = PanelState(
    scrubber: signalC(ScrubberState(
      cursor: max(0, j.events.len - 1),
      total: j.events.len,
      active: false)),
    selectedEvent: NoEvent)

proc handleKey*(state: PanelState, ev: KeyEvent, j: Journal): bool =
  ## Apply one key event to the panel state. Returns true if the
  ## panel should keep running, false to exit.
  ##
  ## Side effects on the journal (rewindTo / resumeLive) happen here
  ## so the caller doesn't have to coordinate between scrubber state
  ## and journal projection.
  case ev.kind
  of kChar:
    if $ev.rune == "q": return false
    return true
  of kArrowLeft, kArrowRight, kEscape:
    # Refresh `total` against the current journal before stepping (new
    # events may have arrived since the panel last refreshed). Pure
    # read-modify-write into the signal so the bindRow observer fires
    # exactly once for the keystroke.
    var cur = state.scrubber.peek()
    cur.total = j.events.len
    let (next, action) = scrubStep(cur, ev)
    state.scrubber.set(next)
    case action
    of saRewind:
      if next.cursor >= 0 and next.cursor < j.events.len:
        rewindTo(j, j.events[next.cursor].id)
    of saResume:
      resumeLive(j)
    of saNone:
      discard
    return true
  of kEnter:
    # Select the event at the scrubber cursor for causal inspection.
    let cur = state.scrubber.peek()
    if cur.cursor >= 0 and cur.cursor < j.events.len:
      state.selectedEvent = j.events[cur.cursor].id
    return true
  else:
    return true

proc snapshotTopology(supervisors: openArray[Supervisor]): seq[TopologyNode] =
  for s in supervisors:
    for n in s.topology(): result.add n

proc runDevtoolsPanel*[S: Sink](j: Journal, supervisors: seq[Supervisor],
                                stream: InputStream, screen: Screen[S])
                                {.async: (raises: [Exception]).} =
  ## Compose the devtools widgets into a running panel against
  ## `screen`. Three vertical regions: task tree (top third),
  ## journal stream (middle third, tail-window via wmFromEnd),
  ## scrubber (bottom third). `q` exits; ←/→ scrub; Escape resumes
  ## live; Enter pins the cursor's event for causal inspection.
  ##
  ## Generic on Sink: production code passes a TerminalScreen; headless
  ## CI tests pass a MemoryScreen and read rendered rows from
  ## `screen.sink.rows`. `paint(screen)` dispatches via the Sink concept.
  # cast(gcsafe): fresco is single-dispatcher; bindCollection isn't
  # statically proven gcsafe because of its closure-capturing handler,
  # but no concurrent thread touches our refs.
  mixin commit, collection, bindRows, bindCollection, bindRow, signal
  {.cast(gcsafe).}:
    let root = newScope()
    try:
      withScope(root):
        let topo   = signalC(snapshotTopology(supervisors))
        let events = collectionC[Event](@[])
        for e in j.events: events.push(e)
        let state = newPanelState(j)

        let h = screen.height
        let thirds = max(1, h div 3)
        let treeR   = newRegion(screen, 0,            0, thirds, screen.width)
        let streamR = newRegion(screen, thirds,       0, thirds, screen.width)
        let scrubR  = newRegion(screen, 2 * thirds,   0,
                                max(1, h - 2 * thirds), screen.width)

        bindRows treeR, 0 ..< treeR.height, [topo]: renderTaskTree(topo)
        bindCollection(streamR, 0 ..< streamR.height, events,
                       proc(e: Event): string = renderEvent(e),
                       mode = wmFromEnd)
        # F-M2: scrubber is a Signal[ScrubberState]; bindRow declares it
        # as a dep, so each ←/→/Escape re-renders the row with the new
        # cursor/total. Alias to a local because the deps bracket needs
        # a plain ident (the binding macro shadows by name).
        let scrubber = state.scrubber
        bindRow scrubR, 0, [scrubber]:
          renderScrubber(scrubber.cursor, scrubber.total,
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
