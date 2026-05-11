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

template hotkey*(stream: InputStream, key: KeyEvent, body: untyped): untyped =
  ## Run `body` when the given key arrives on `stream`. Auto-unregisters
  ## on scope dispose.
  let handle = stream.addFilter(proc(ev: KeyEvent): bool =
    if ev == key:
      body
      return true
    return false)
  onCleanup proc() = stream.removeFilter(handle)
