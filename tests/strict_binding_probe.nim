{.experimental: "callOperator".}

## Proof-of-discipline: fresco's row bindings over `signals:`-baked signals
## classify STATIC and compile clean under `-d:intonacoStrict`. `setRow` is
## effect-transparent, so `effect:` schedules the binding at compile time rather
## than falling to the runtime floor. Verified by `nimble strictcheck`, not the
## runtime suite (a strict misclassification would be a hard compile error).

import intonaco/reactive/signal
import fresco/reactive/binding

type Screen = ref object
  rows: seq[string]
proc setRow(s: Screen, i: int, c: string) =
  if i >= 0 and i < s.rows.len: s.rows[i] = c
proc height(s: Screen): int = s.rows.len

let screen = Screen(rows: newSeq[string](5))
signals:
  count = 0
  title = "hello"

bindRow(screen, 0, [title], title)                      # direct baked read -> static
bindRow(screen, 1, [count], "count: " & $count)         # baked read in an expression
bindRows(screen, 2 .. 4, [], @["a", "b", "c"])          # constant -> static
