## Auto state restoration on supervisor restart.
##
##   sup.addChild("agent", lcTransient, agentLoop, onRestart = orReplayJournal)
##
## `orReplayJournal` is a `RestartHandler` that walks
## `lastWritesByLabel(prevTid)` and stages each label→writeRepr pair
## in a thread-local table. On the subsequent re-spawn, the new task
## body's `signal(initial, label = "name")` constructions check the
## staging table; if a matching label is present and the writeRepr
## parses as the signal's value type, the parsed value replaces the
## declared initial. Each entry is consumed (read-and-remove) on its
## first match, so a body declaring two signals with the same label
## restores only the first.
##
## Supported types: int, float, bool, string. Other types fall through
## to the declared initial (no auto-restore; user writes a manual
## `onRestart` if needed). Parse failures log to stderr and use the
## initial — corrupt journal entries don't crash the new task.

import std/[strutils, tables]
import ../journal/events
import ../journal/log
import ./scope

var pendingRestoration* {.threadvar.}: Table[string, string]
  ## Staging slot written by `orReplayJournal` immediately before the
  ## supervisor's re-spawn. The signal constructor reads-and-removes
  ## from this table during the new task's synchronous body setup.
  ## Module-internal mutation is fine; tests can inspect for white-box
  ## invariants (e.g., emptied after body setup completes).

var pendingRestorationSource* {.threadvar.}: TaskId
  ## TaskId of the prior task whose writes `pendingRestoration` was
  ## seeded from. Read by `consumeRestoration` to populate the
  ## `restoredFromTaskId` field of the audit event. Set by
  ## `orReplayJournal` immediately before staging.

proc auditRestored(label, repr: string) =
  ## Emit `ekSignalRestored` for a successful restoration. Attributes
  ## to the current scope's taskId (the new task) and the staged
  ## sourceTaskId (the prior task whose write is being replayed).
  ## No-ops outside a scope or when the global journal isn't set.
  if globalJournal == nil: return
  let cs = currentScope
  if cs == nil: return
  discard globalJournal.logSignalRestored(
    cs.taskId, cs.lastEventId,
    label, repr, pendingRestorationSource)

proc tryConsumeRepr*(label: string): tuple[hit: bool, repr: string] =
  ## Internal helper for `consumeRestoration`. Looks up `label` in
  ## `pendingRestoration`; on hit, removes the entry and returns the
  ## stored repr. Kept out of the template body so callers don't need
  ## `import std/tables` for the `in` / `del` operators.
  if label.len > 0 and label in pendingRestoration:
    result.hit = true
    result.repr = pendingRestoration[label]
    pendingRestoration.del(label)
  else:
    result.hit = false

template consumeRestoration*[T](label: string, fallback: T): T =
  ## Look up `label` in `pendingRestoration`. If present and parseable
  ## as `T`, remove the entry, journal an `ekSignalRestored` audit
  ## event, and return the parsed value. Otherwise return `fallback`.
  ##
  ## Implemented as a **template** so the `when compiles(restore(...))`
  ## branch resolves at the call site — user-defined `restore`
  ## overloads (for #46 custom types) defined in the caller's module
  ## are visible. A generic proc with `mixin` doesn't propagate
  ## through nested generics (signal[T] → consumeRestoration[T]);
  ## template expansion sidesteps that. The actual table interaction
  ## lives in `tryConsumeRepr` to avoid forcing callers to import
  ## `std/tables`.
  ##
  ## Empty labels short-circuit (unlabeled signals are excluded from
  ## restoration projection — see `lastWritesByLabel`).
  block:
    mixin restore
    var outVal: T = fallback
    let lookup = tryConsumeRepr(label)
    if lookup.hit:
      let repr = lookup.repr
      when T is int:
        try:
          outVal = parseInt(repr)
          auditRestored(label, repr)
        except ValueError:
          stderr.writeLine "orReplayJournal: couldn't parse '" & repr &
            "' as int for signal '" & label & "' — using declared initial"
      elif T is float:
        try:
          outVal = parseFloat(repr)
          auditRestored(label, repr)
        except ValueError:
          stderr.writeLine "orReplayJournal: couldn't parse '" & repr &
            "' as float for signal '" & label & "' — using declared initial"
      elif T is bool:
        try:
          outVal = parseBool(repr)
          auditRestored(label, repr)
        except ValueError:
          stderr.writeLine "orReplayJournal: couldn't parse '" & repr &
            "' as bool for signal '" & label & "' — using declared initial"
      elif T is string:
        outVal = repr
        auditRestored(label, repr)
      elif compiles(restore(repr, T)):
        # User-defined `restore(s: string, _: typedesc[T]): T` overload
        # in scope at the template call site (#46). Nim resolves at
        # compile time via overload resolution — no registration call
        # needed.
        try:
          outVal = restore(repr, T)
          auditRestored(label, repr)
        except CatchableError as e:
          stderr.writeLine "orReplayJournal: user `restore` raised " &
            e.msg & " for signal '" & label & "' — using declared initial"
      # else: no `restore` overload in scope; silent fall-through.
    outVal

proc orReplayJournal*(j: Journal, prev: TaskId) {.gcsafe.} =
  ## A `RestartHandler` that primes `pendingRestoration` from the
  ## prior task's labeled signal writes. Pass as bare name:
  ## `onRestart = orReplayJournal`.
  pendingRestoration = initTable[string, string]()
  pendingRestorationSource = prev
  let writes = j.lastWritesByLabel(prev)
  for label, ev in writes:
    pendingRestoration[label] = ev.writeRepr

proc orReplayJournal*(filter: proc(label: string): bool
                              {.closure, gcsafe.}): proc(j: Journal, prev: TaskId)
                                                    {.closure, gcsafe.} =
  ## Factory variant: returns a `RestartHandler` that only stages
  ## labels for which `filter(label)` returns true. Use as:
  ##
  ##   onRestart = orReplayJournal(
  ##     proc(l: string): bool = l.startsWith("ui."))
  ##
  ## Selective replay (#47): scope restoration to a subset of labels.
  ## Manual onRestart remains the escape hatch for more complex
  ## filtering or transformation needs.
  let f = filter
  result = proc(j: Journal, prev: TaskId) {.closure, gcsafe.} =
    pendingRestoration = initTable[string, string]()
    pendingRestorationSource = prev
    let writes = j.lastWritesByLabel(prev)
    for label, ev in writes:
      if f(label):
        pendingRestoration[label] = ev.writeRepr
