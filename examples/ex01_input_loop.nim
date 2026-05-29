## Echo every decoded KeyEvent. Ctrl-C to quit.
##
## Visual check: every key you press should print the right semantic
## name. Arrow keys → kArrowUp/Down/etc., function keys → kF1..kF12,
## Ctrl combos → "Ctrl-<r>" via the modifier set, `/` → kChar '/'.

import std/unicode
import chronos
import fresco/input as fi
import fresco/events

proc describe(ev: KeyEvent): string =
  # The modifier-set model (#67): `Ctrl-c` is `(kChar 'c', {modCtrl})`,
  # not a separate `kCtrl` kind. summary() handles the prefix.
  ev.summary

proc main() {.async: (raises: [CancelledError, Exception]).} =
  let stream = newInputStream(cint(0))
  fi.start(stream)
  defer: fi.stop(stream)
  stderr.writeLine "input loop — press keys; Ctrl-C to quit"
  while true:
    let ev = await stream.nextKey()
    stderr.writeLine describe(ev)
    if ev.kind == kChar and ev.rune == Rune('c') and modCtrl in ev.modifiers:
      break

waitFor main()
