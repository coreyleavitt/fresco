## Speculative scopes — try-a-change-and-decide.
##
##   speculative:
##     editor.text := newText
##     cursor     := newCursor
##     savedAt    := now()
##     if await confirm("commit?"):
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
## Single-threaded chronos: no isolation needed — other coroutines
## don't run during the speculative block.

type
  SpeculativeScope* = ref object
    parent*: SpeculativeScope
    reverts*: seq[proc() {.closure.}]
    committed*: bool

var currentSpeculative* {.threadvar.}: SpeculativeScope

proc recordRevert*(p: proc() {.closure.}) {.gcsafe.} =
  ## Push a revert closure onto the active speculative frame. No-op
  ## outside any speculative scope or after the frame committed.
  {.cast(gcsafe).}:
    if currentSpeculative != nil and not currentSpeculative.committed:
      currentSpeculative.reverts.add p

proc rollback*(scope: SpeculativeScope) {.gcsafe.} =
  ## Run all queued reverts in reverse order. Idempotent.
  {.cast(gcsafe).}:
    for i in countdown(scope.reverts.high, 0):
      try: scope.reverts[i]()
      except Exception: discard
    scope.reverts.setLen(0)
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
      frame.committed = true
      frame.reverts.setLen(0)
    template discardSpeculative() {.inject, used.} =
      rollback(frame)
    var raised = false
    try:
      body
    except CatchableError:
      raised = true
      rollback(frame)
      currentSpeculative = prevSpec
      raise
    if not raised and not frame.committed:
      rollback(frame)
    currentSpeculative = prevSpec
    frame
