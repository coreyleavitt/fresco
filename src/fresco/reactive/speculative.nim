## Speculative scopes — try-a-change-and-decide.
##
##   speculative:
##     editor.text := newText
##     cursor     := newCursor
##     savedAt    := now()
##     if commitReady():
##       commit()
##     # else: auto-rollback on block exit
##
## Semantics:
##   - signal writes inside the block immediately mutate the underlying
##     signal value AND notify observers, so reads inside the block
##     see the new state.
##   - each write also pushes a revert closure onto a frame-local stack.
##   - on `commit()`: the frame is marked committed; revert stack is
##     cleared; writes stick.
##   - on falling out of the block without committing, or on raising:
##     the reverts replay in reverse and observers re-notify, so the
##     world returns to its pre-block state.
##
## **Awaiting inside a speculative body is safe** as long as the
## enclosing async proc is annotated `{.task.}` — fresco's CLS
## substrate restores `currentSpeculative` after every suspension,
## so writes from sibling coroutines that ran during the suspension
## don't land on our revert stack. Without `{.task.}`, the active
## frame is lost across the suspend and any signal write while
## suspended would erroneously be tracked on our frame.

type
  SpeculativeScope* = ref object
    parent*: SpeculativeScope
    reverts: seq[proc() {.closure.}]   ## internal — populated via recordRevert
    committed*: bool

var currentSpeculative* {.threadvar.}: SpeculativeScope

proc recordRevert*(p: proc() {.closure.}) {.gcsafe.} =
  ## Push a revert closure onto the active speculative frame. No-op
  ## outside any speculative scope or after the frame committed.
  {.cast(gcsafe).}:
    if currentSpeculative != nil and not currentSpeculative.committed:
      currentSpeculative.reverts.add p

proc rollback*(scope: SpeculativeScope) {.gcsafe.} =
  ## Run all queued reverts in reverse order. Reverts trigger observer
  ## notifications whose own writes can push *new* reverts onto the
  ## same frame; we drain those too. Idempotent.
  ##
  ## A revert closure that raises `CatchableError` would leave state
  ## half-rolled-back with no diagnostic — surface it on stderr so the
  ## bug isn't silent. Defects propagate (the outer finally in the
  ## `speculative:` template still restores `currentSpeculative`).
  {.cast(gcsafe).}:
    while scope.reverts.len > 0:
      let r = scope.reverts.pop()
      try: r()
      except CatchableError as e:
        try:
          stderr.writeLine("fresco speculative revert raised: " &
                           $e.name & ": " & e.msg)
        except IOError: discard
    scope.committed = true

template speculative*(body: untyped): SpeculativeScope =
  ## Open a speculative frame, run `body`, return the frame. Inside
  ## the body, call `commit()` to make the writes stick; otherwise
  ## the frame auto-rolls back on exit.
  block:
    let prevSpec = currentSpeculative
    let frame = SpeculativeScope(parent: prevSpec)
    currentSpeculative = frame
    template commit() {.inject, used.} =
      ## End the speculative transaction: writes become canonical.
      ## After `commit()` any further `signal.set` inside the same
      ## `speculative:` block also sticks (no reverts are recorded),
      ## so writes that happen after-commit-before-block-end are
      ## logically part of the same canonical branch.
      ##
      ## Note: this template injects the name `commit` into the
      ## enclosing scope for the duration of the body. If you have a
      ## user-defined `commit` symbol in scope (e.g. a DB client
      ## method), reference it qualified inside `speculative:`.
      ##
      # If we're nested, promote our reverts into the parent frame so
      # an outer rollback still undoes our writes. MVCC: an inner
      # commit only means "merge into the parent branch", not "make
      # canonical regardless of outer outcome."
      if frame.parent != nil:
        for r in frame.reverts:
          frame.parent.reverts.add r
      frame.committed = true
      frame.reverts.setLen(0)
    # Rollback + threadvar restore unified into nested finallys so any
    # exit path — normal return without commit, CatchableError, or
    # Defect — leaves the world consistent. The inner finally runs
    # rollback (best-effort: a Defect from a revert closure propagates,
    # which is fine — those represent unrecoverable bugs). The outer
    # finally unconditionally restores `currentSpeculative`, so even
    # if rollback raises a Defect we don't leak the threadvar pointing
    # at a dead frame.
    try:
      try:
        body
      finally:
        if not frame.committed: rollback(frame)
    finally:
      currentSpeculative = prevSpec
    frame
