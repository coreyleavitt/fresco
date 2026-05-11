## Echo every decoded KeyEvent. Ctrl-C to quit.
##
## Visual check: every key you press should print the right semantic
## name. Arrow keys → kArrowUp/Down/etc., function keys → kF1..kF12,
## Ctrl combos → kCtrl with the letter, `/` → kChar '/'.

import std/unicode
import chronos
import fresco/input as fi
import fresco/events

proc describe(ev: KeyEvent): string =
  case ev.kind
  of kChar: "kChar " & $ev.rune
  of kCtrl: "kCtrl-" & $ev.ch
  of kAlt:  "kAlt-"  & $ev.ch
  else:     $ev.kind

proc main() {.async: (raises: [CancelledError, Exception]).} =
  let stream = newInputStream(cint(0))
  fi.start(stream)
  defer: fi.stop(stream)
  stderr.writeLine "input loop — press keys; Ctrl-C to quit"
  while true:
    let ev = await stream.nextKey()
    stderr.writeLine describe(ev)
    if ev.kind == kCtrl and ev.ch == 'c': break

waitFor main()
