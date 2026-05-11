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
##   proc app(stream: InputStream, screen: Screen) {.task, async.} =
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
##       receive stream:
##         Char('+'): count := count() + 1
##         Char('-'): count := count() - 1
##         after 1.seconds: discard          # idle tick
##
## The `{.task, async.}` pragma combination is load-bearing: `task`
## must run *before* `async` (pragmas are processed left-to-right),
## so the CLS substrate gets to rewrite every `await` in the body
## before chronos transforms it into a state machine. Without `task`
## the reactive `currentScope` is silently lost across every suspend.
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
import fresco/reactive/speculative
import fresco/reactive/animation
import fresco/reactive/collection
import fresco/reactive/static_graph
import fresco/reactive/capabilities
export scope, signal, binding, context, speculative, animation, collection,
       static_graph, capabilities

# T4 — task
import fresco/task/core
import fresco/task/cls
import fresco/task/receive
import fresco/task/parallel
import fresco/task/mount
import fresco/task/hotkey
import fresco/task/supervisor
export core, cls, receive, parallel, mount, hotkey, supervisor

# T4 — journal (v2.1 + v2.4)
import fresco/journal/events as journal_events
import fresco/journal/log    as journal_log
import fresco/journal/persist as journal_persist
export journal_events, journal_log, journal_persist
