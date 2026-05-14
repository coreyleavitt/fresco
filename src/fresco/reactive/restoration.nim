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

var pendingRestoration* {.threadvar.}: Table[string, string]
  ## Staging slot written by `orReplayJournal` immediately before the
  ## supervisor's re-spawn. The signal constructor reads-and-removes
  ## from this table during the new task's synchronous body setup.
  ## Module-internal mutation is fine; tests can inspect for white-box
  ## invariants (e.g., emptied after body setup completes).

proc consumeRestoration*[T](label: string, fallback: T): T =
  ## Look up `label` in `pendingRestoration`. If present and parseable
  ## as `T`, remove the entry and return the parsed value; otherwise
  ## return `fallback`. Empty labels short-circuit.
  ##
  ## Called from `signal()` on every construction — the short-circuit
  ## keeps the non-restoration path at one table lookup per signal.
  if label.len == 0 or label notin pendingRestoration:
    return fallback
  let repr = pendingRestoration[label]
  pendingRestoration.del(label)
  when T is int:
    try: result = parseInt(repr)
    except ValueError:
      stderr.writeLine "orReplayJournal: couldn't parse '" & repr &
        "' as int for signal '" & label & "' — using declared initial"
      result = fallback
  elif T is float:
    try: result = parseFloat(repr)
    except ValueError:
      stderr.writeLine "orReplayJournal: couldn't parse '" & repr &
        "' as float for signal '" & label & "' — using declared initial"
      result = fallback
  elif T is bool:
    try: result = parseBool(repr)
    except ValueError:
      stderr.writeLine "orReplayJournal: couldn't parse '" & repr &
        "' as bool for signal '" & label & "' — using declared initial"
      result = fallback
  elif T is string:
    result = repr
  else:
    # Unsupported type — silent fall-through. User writes a manual
    # onRestart, or registers a custom restorer (#46).
    result = fallback

proc orReplayJournal*(j: Journal, prev: TaskId) {.gcsafe.} =
  ## A `RestartHandler` that primes `pendingRestoration` from the
  ## prior task's labeled signal writes. Pass as
  ## `onRestart = orReplayJournal` to `addChild`.
  pendingRestoration = initTable[string, string]()
  let writes = j.lastWritesByLabel(prev)
  for label, ev in writes:
    pendingRestoration[label] = ev.writeRepr
