## fresco — terminal-UI kernel for Nim.
##
## Single-import entry. See DESIGN.md for architecture. A typical
## amoxtli-flavored app:
##
##   import fresco
##   import chronos
##
##   proc app(stream: InputStream, screen: Screen) {.async.} =
##     state:
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
##       receive stream:
##         Char('+'): count := count() + 1
##         Char('-'): count := count() - 1
##         after 1.seconds: discard          # idle tick
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
import fresco/reactive/scope
import fresco/reactive/signal
import fresco/reactive/binding
import fresco/reactive/context
export scope, signal, binding, context

# T4 — task
import fresco/task/core
import fresco/task/receive
import fresco/task/parallel
import fresco/task/mount
import fresco/task/hotkey
import fresco/task/supervisor
export core, receive, parallel, mount, hotkey, supervisor

# T4 — journal (v2.1)
import fresco/journal/events as journal_events
import fresco/journal/log    as journal_log
export journal_events, journal_log
