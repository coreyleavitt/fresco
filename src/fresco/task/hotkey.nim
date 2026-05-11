## Scope-bound keyboard hotkey.
##
##   hotkey stream, ctrlKey('q'):
##     app.shutdown()
##
##   hotkey stream, simple(kF1):
##     showHelp()
##
## Hotkeys register a pre-filter on the InputStream — they see every
## key before the regular `receive` mailbox and can consume the event,
## stopping it from reaching the receive loop. Lifetime is bound to
## the enclosing scope: when the scope disposes, the filter unregisters.
##
## Pattern matching is intentionally simpler than `receive:` — exact
## KeyEvent comparison. Use helper constructors (`ctrlKey('c')`,
## `simple(kF1)`, `charKey(Rune('?'))`) to build the matcher.

import ../events
import ../input
import ../reactive/scope
import ../journal/events as jev
import ../journal/log

template hotkey*(stream: InputStream, key: KeyEvent, body: untyped): untyped =
  ## Run `body` when the given key arrives on `stream`. Auto-unregisters
  ## on scope dispose. When matched, journals an ekKeyConsumed event
  ## so devtools can see which hotkey ate the input.
  ##
  ## The registering scope is captured at template instantiation so
  ## the journal event is attributed to the correct task, not to
  ## whatever scope happens to be current inside the chronos read
  ## callback (which is usually nil).
  let owningScope = currentScope
  let handle = stream.addFilter(proc(ev: KeyEvent): bool =
    if ev == key:
      if globalJournal != nil:
        let tid = if owningScope != nil: owningScope.taskId else: jev.RootTask
        let parent = if owningScope != nil: owningScope.lastEventId else: jev.NoEvent
        try:
          let id = globalJournal.logKeyConsumed(tid, parent, ev.summary)
          if owningScope != nil: owningScope.lastEventId = id
        except CatchableError: discard
      body
      return true
    return false)
  onCleanup proc() = stream.removeFilter(handle)
