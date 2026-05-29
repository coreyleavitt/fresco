{.experimental: "callOperator".}

## Proof-of-discipline (F-M3): fresco's full binding surface compiles clean
## under `-d:intonacoStrict` over `signals:`-baked sources and `collections:`-
## baked sources. Every shape is exercised at least once so a strict
## misclassification anywhere — bindRow / bindRows / bindCollection / region
## DSL / computed / effect — is a hard compile error.
##
## This is the regression contract for the C-shape discipline. Pair with
## `examples/stopwatch.nim` which is the same discipline at a higher level
## (real composition, lifecycle, input loop).

import std/[unicode]
import intonaco/reactive/primitives/signal
import intonaco/reactive/primitives/scope
import intonaco/reactive/dsl/binding         # `computed`, `effect`
import intonaco/reactive/primitives/collection      # `collections:`, `CollectionSignal`
import intonaco/task/mount               # `mountWhen`
import intonaco/task/core                # `Mount` / `spawn`
import chronos                            # so `spawn`'s child future type resolves
import fresco/reactive/binding as fresco_binding

# --- Minimal screen-like target -------------------------------------------

type Screen = ref object
  rows: seq[string]
proc setRow(s: Screen, i: int, c: string) =
  if i >= 0 and i < s.rows.len: s.rows[i] = c
proc height(s: Screen): int = s.rows.len

let screen = Screen(rows: newSeq[string](10))

# --- Baked sources --------------------------------------------------------

signals:
  count   = 0
  title   = "hello"
  total   = 100
  running = false

collections:
  laps = newSeq[int]()

# --- bindRow / bindRows ---------------------------------------------------

bindRow(screen, 0, [title], title)                     # direct baked read
bindRow(screen, 1, [count, total], $count & "/" & $total)
bindRow(screen, 2, [], "constant header")              # empty deps OK

bindRows(screen, 3 .. 4, [], @["a", "b"])              # constant seq[string]
bindRows(screen, 5 .. 6, [count],                       # baked dep in body
         @[$count, "second"])

# --- computed / effect ----------------------------------------------------

computed pct, [count, total]:                          # chained over signals:
  if total > 0: (count * 100) div total
  else: 0

bindRow(screen, 7, [pct], $pct & "%")                  # pct's baked height feeds
                                                        # downstream binding

effect [count]:                                        # side-effecting form
  discard count                                         # walker-clean: only `count`

# --- region DSL -----------------------------------------------------------

discard createRoot:
  region(screen):
    row 0,         [title]:  title
    row ^1,        [count]:  "tail: " & $count
    rows 8 .. 9,   [pct]:    @["pct=" & $pct, "frame"]

# --- bindCollection over a `collections:`-baked CollectionSignal ----------

discard createRoot:
  bindCollection(screen, 3 .. 5, laps, proc(x: int): string = $x)

# --- mountWhen (decide / act seam over a baked Signal[bool]) --------------

proc worker(): Future[void] {.async: (raises: [Exception]).} =
  await sleepAsync(0.milliseconds)

discard createRoot:
  mountWhen(running):
    spawn worker()
