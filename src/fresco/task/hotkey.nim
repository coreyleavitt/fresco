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
  let handle = stream.addFilter(proc(ev: KeyEvent): bool =
    if ev == key:
      if globalJournal != nil:
        let tid = if currentScope != nil: currentScope.taskId else: jev.RootTask
        let parent = if currentScope != nil: currentScope.lastEventId else: jev.NoEvent
        try:
          let id = globalJournal.logKeyConsumed(tid, parent, ev.summary)
          if currentScope != nil: currentScope.lastEventId = id
        except Exception: discard
      body
      return true
    return false)
  onCleanup proc() = stream.removeFilter(handle)
