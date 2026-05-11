## Capability markers and the `requires` annotation.
##
## Capabilities are opaque ref types that travel through the existing
## `provide T: v` / `use T` substrate. A capability is *granted* by
## providing its marker somewhere up the scope chain; a task that
## needs the capability calls `use FsReadCap` (or uses the `requires`
## macro), which raises MissingProviderError if no ancestor granted it.
##
##   # at app root, somewhere up the supervisor chain:
##   provide FsReadCap(),  provide ProcessCap()
##
##   # in a task that touches the filesystem:
##   task readConfig() =
##     requires(FsReadCap)            # ← asserts; raises if missing
##     let data = readFile("conf.toml")
##     ...
##
## Standard markers cover the broad axes of dangerous side effects:
## filesystem reads/writes, process spawning, network access, terminal
## I/O, mutable state. Apps can declare their own markers the same
## way (any `ref object` works as a capability).
##
## v2.4 ships the runtime-checked layer using the existing `provide`/
## `use` machinery — no separate cap registry. Future work: a typed
## macro that walks task bodies, identifies primitive uses (readFile,
## openProcess, etc.), and *automatically* emits the matching
## `requires` annotations. That would lift the check from runtime to
## compile time along statically-known supervisor paths.

import std/macros
import ./context

type
  FsReadCap*    = ref object   ## read from local filesystem
  FsWriteCap*   = ref object   ## write to local filesystem
  ProcessCap*   = ref object   ## spawn / exec OS processes
  NetworkCap*   = ref object   ## socket / DNS / HTTP
  TerminalCap*  = ref object   ## raw-mode TTY I/O (implicit for UI tasks)
  StateMutCap*  = ref object   ## mutate reactive state (implicit for reactive tasks)

macro requires*(caps: varargs[untyped]): untyped =
  ## Assert that every capability in `caps` is provided by some
  ## ancestor scope. Each one expands to a `discard use(Cap)` which
  ## raises MissingProviderError at runtime if missing.
  ##
  ## Compile-time discharge along static supervisor topology is a
  ## later v2.4 enhancement; for now this is runtime-checked.
  result = newStmtList()
  for cap in caps:
    result.add quote do:
      discard use(`cap`)
