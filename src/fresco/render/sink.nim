## Sink — the commit-destination abstraction for Layouts.
##
## A Sink consumes a Layout's composed state and emits it to its
## medium of choice. The terminal sink emits ANSI escapes to a file
## descriptor; the memory sink captures content in-memory for tests
## and headless consumers; future sinks (file, web socket, IPC)
## follow the same pattern.
##
## Sink is a structural concept: any type with `commit(Layout)`
## satisfies it. No inheritance hierarchy, no virtual dispatch —
## the binding from a sink type to its commit logic is purely at
## compile time. Different sinks live in different submodules
## (`sink/terminal`, `sink/memory`, etc.) and consumers import the
## ones they need.

import ./layout

type
  Sink* = concept s
    ## Any value `s` for which `s.commit(layout)` compiles.
    s.commit(default(Layout))
