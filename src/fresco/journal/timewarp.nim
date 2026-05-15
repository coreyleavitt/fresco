## Time-warp: project live signals back to historical journal state.
##
##   bindForTimeWarp(cursor)        # cursor: Signal[int] with a label
##   rewindTo(j, eventIdAtCursor)   # scrub: signal sees historical value
##   resumeLive(j)                  # release: back to head state
##
## `bindForTimeWarp` registers a per-signal applier closure keyed by the
## signal's label. The closure parses a writeRepr string and writes
## the parsed value back via `setUntracked` (so projection doesn't
## journal new entries). `rewindTo(j, cutoff)` consults
## `j.stateAt(cutoff)` and invokes the applier for every projected
## label. `resumeLive(j)` re-applies head state, then clears the
## rewinding flag.
##
## Supported value types: int, float, bool, string. Other types fall
## through to a user `restore(repr, T): T` overload (same mechanism as
## restoration.nim's #46 path) — define one in the calling module to
## make a custom signal time-warpable.
##
## Lifetime: `bindForTimeWarp` registers an `onCleanup` against the
## current scope so the applier is unregistered when that scope
## disposes. Calling outside any scope is allowed but the binding
## then lives until process exit (no scope to hang the cleanup on).

import std/[strutils, tables]
import ./events
import ./log
import ../reactive/scope
import ../reactive/signal

type
  SignalApplier* = proc(repr: string) {.closure, gcsafe, raises: [].}

var signalAppliersByLabel {.threadvar.}: Table[string, SignalApplier]
  ## The rewinding flag itself lives in `journal/log.nim` (re-exported
  ## as `isRewinding`) so `signal.setCore` can read it without an
  ## import cycle. See `log.rewindingFlag` for the contract.

export isRewinding

proc registerApplier*(label: string, applier: SignalApplier) =
  ## Install an applier closure under `label`. If a scope is current,
  ## register an `onCleanup` that removes the binding on dispose.
  ## Module-internal — `bindForTimeWarp` is the user-facing entry.
  if label.len == 0: return
  signalAppliersByLabel[label] = applier
  if currentScope != nil:
    let cleanupLabel = label
    onCleanup proc() =
      if cleanupLabel in signalAppliersByLabel:
        signalAppliersByLabel.del(cleanupLabel)

template bindForTimeWarp*[T](s: Signal[T]) =
  ## Register `s` as projectable by `rewindTo` / `resumeLive`. Requires
  ## `s.label` to be non-empty; an unlabeled signal can't be matched
  ## against journal writeReprs (those are keyed by label).
  ##
  ## Implemented as a **template** so the `when compiles(restore(...))`
  ## branch resolves at the call site — user-defined `restore`
  ## overloads in the caller's module are visible. A generic proc with
  ## `mixin` doesn't propagate through nested generics; template
  ## expansion sidesteps that (same shape as `consumeRestoration`).
  ##
  ## Last-registration-wins per label: rebinding the same label
  ## replaces the prior applier. Labels must be unique among
  ## time-warped signals; sharing a label is a configuration error.
  ##
  ## Lifetime: when called inside a scope, the binding auto-unregisters
  ## on scope dispose (mirrors the cleanup pattern used by `tween` /
  ## `spring`). Outside a scope, the binding lives until process exit.
  block:
    mixin restore
    if s.label != "":
      let captured = s
      let captLabel = s.label
      let applier: SignalApplier =
        proc(repr: string) {.closure, gcsafe, raises: [].} =
          # cast(gcsafe): the captured Signal[T] is held by closure
          # ref; Nim's gcsafe analysis can't prove the closure-capture
          # is safe when the template expands in a non-gcsafe scope.
          # fresco is single-dispatcher so there is no real race.
          {.cast(gcsafe).}:
            when T is int:
              try: captured.setUntracked(parseInt(repr))
              except ValueError: discard
            elif T is float:
              try: captured.setUntracked(parseFloat(repr))
              except ValueError: discard
            elif T is bool:
              try: captured.setUntracked(parseBool(repr))
              except ValueError: discard
            elif T is string:
              captured.setUntracked(repr)
            elif compiles(restore(repr, T)):
              try: captured.setUntracked(restore(repr, T))
              except CatchableError: discard
            else:
              {.error: "bindForTimeWarp: T must be int|float|bool|string " &
                       "or have a `restore(repr: string, _: typedesc[T]): T` overload".}
      registerApplier(captLabel, applier)

proc rewindTo*(j: Journal, cutoff: EventId) =
  ## Project every time-warp-bound signal back to its journaled value
  ## at `cutoff`. Uses `stateAt` for the per-label last-write-wins
  ## projection. Sets `isRewinding()` true; projection writes use
  ## `setUntracked` so no new journal entries are produced.
  log.rewindingFlag = true
  let projected = j.stateAt(cutoff)
  for label, repr in projected:
    if label in signalAppliersByLabel:
      signalAppliersByLabel[label](repr)

proc resumeLive*(j: Journal) =
  ## Re-apply head state to every bound signal, then clear the
  ## rewinding flag. After this call, `isRewinding()` is false and
  ## bound signals hold their most-recent journaled values.
  if j.events.len > 0:
    let head = j.events[^1].id
    let projected = j.stateAt(head)
    for label, repr in projected:
      if label in signalAppliersByLabel:
        signalAppliersByLabel[label](repr)
  log.rewindingFlag = false
