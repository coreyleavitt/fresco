## fresco — terminal-UI kernel for Nim.
##
## Single-import entry. See DESIGN.md for architecture.
##
## **Caller setup:** if you want to use the `count()` read sugar
## (instead of `count.get()`), enable the experimental pragma in your
## own module:
##
##   {.experimental: "callOperator".}
##
## Nim's experimental pragmas don't propagate from imported modules,
## so enabling it inside fresco only lets fresco *define* the `()`
## overload — call sites still need their own pragma. The qualified
## `count.get()` form works without it.
##
## A typical amoxtli-flavored app:
##
##   {.experimental: "callOperator".}    # enable count() read sugar
##   import fresco
##   import chronos
##
##   proc app(stream: InputStream, screen: Screen) {.async.} =
##     signals:
##       count = 0
##       title = "demo"
##
##     let panel = newRegion(screen, 0, 0, 5, screen.width)
##     region(panel):
##       row 0: title()
##       row 1: $count() & " items"
##
##     hotkey stream, ctrlKey('q'): return
##
##     while true:
##       receive:
##         on stream as ev:
##           Char('+'): count := count() + 1
##           Char('-'): count := count() - 1
##         after 1.seconds: discard          # idle tick
##
## Plain `{.async.}` is enough — `currentScope` is a chronos
## contextVar (since #40), so the binding propagates through every
## `await` automatically. No `{.task.}` pragma, no `taskAwait`
## helper, no fresco-side CLS substrate.
##
## Re-exports the T4 reactive + task surface plus the underlying
## T1-T3 primitives needed at user code: KeyEvent constructors,
## Region / Screen, layout helpers.

{.experimental: "callOperator".}

# T1 — terminal foundation
import fresco/terminal/ansi
import fresco/terminal/termios
import fresco/events
import fresco/input
export ansi, termios, events, input

# T2 — region + render
import fresco/screen
import fresco/render
export screen, render

# T3 — layout
import fresco/layout
export layout

# T4 — reactive
import intonaco/reactive/primitives/scope
import intonaco/reactive/primitives/signal
import fresco/reactive/binding
import intonaco/reactive/primitives/context
import intonaco/reactive/primitives/speculative
import intonaco/reactive/dsl/animation
import intonaco/reactive/primitives/collection
import intonaco/reactive/capabilities
export scope, signal, binding, context, speculative, animation, collection,
       capabilities

# T4 — task
import intonaco/task/core

import fresco/receive
import intonaco/task/parallel
import intonaco/task/mount
import fresco/hotkey
import intonaco/task/supervisor
export core, receive, parallel, mount, hotkey, supervisor

# T4 — journal (v2.1 + v2.4)
import intonaco/journal/events as journal_events
import intonaco/journal/log    as journal_log
import intonaco/journal/persist as journal_persist
export journal_events, journal_log, journal_persist
