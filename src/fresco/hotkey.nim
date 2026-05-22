## Scope-bound keyboard hotkey.
##
##   hotkey stream, ctrlKey('q'):
##     app.shutdown()
##
##   hotkey stream, atomKey(kF1):
##     showHelp()
##
## Hotkeys register a pre-filter on the InputStream — they see every
## key before the regular `receive` mailbox and can consume the event,
## stopping it from reaching the receive loop. Lifetime is bound to
## the enclosing scope: when the scope disposes, the filter unregisters.
##
## Pattern matching is intentionally simpler than `receive:` — exact
## KeyEvent comparison. Use helper constructors (`ctrlKey('c')`,
## `atomKey(kF1)`, `charKey(Rune('?'))`) to build the matcher.

import chronos/contextvars
import ./events
import ./input
import intonaco/reactive/scope
import intonaco/journal/events as jev
import intonaco/journal/log

template hotkey*(stream: InputStream, key: KeyEvent, body: untyped): untyped =
  ## Run `body` when the given key arrives on `stream`. Auto-unregisters
  ## on scope dispose. When matched, journals an ekKeyConsumed event
  ## so devtools can see which hotkey ate the input.
  ##
  ## The registering context is captured at template instantiation and
  ## restored around both the journal write and the user-supplied
  ## `body` — the filter callback fires from chronos's read hook with
  ## a stale `currentScope`, so signal writes / spawns inside `body`
  ## would otherwise attribute to the wrong owner.
  let hotkeyCtx = currentContext()
  let handle = stream.addFilter(proc(ev: KeyEvent): bool =
    if ev == key:
      withContext(hotkeyCtx):
        journalEvent: jrnl.logKeyConsumed(taskTid, parentEvt, ev.summary)
        body
      return true
    return false)
  onCleanup proc() = stream.removeFilter(handle)
