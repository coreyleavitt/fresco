## Continuation-local storage substrate tests.

import std/unittest
import chronos
import fresco

type Box = ref object
  before: Scope
  after: Scope
  got: int
  scopes: seq[Scope]
  inFrame: bool

suite "CLS — currentScope survives await":

  test "scope captured before await equals scope visible after await":
    let b = Box()

    proc inner(b: Box) {.task, async.} =
      b.before = currentScope
      await sleepAsync(2.milliseconds)
      b.after = currentScope

    let root = createRoot:
      discard
    withScope(root):
      let m = spawn inner(b)
      waitFor m.future

    check b.before != nil
    check b.after == b.before
    dispose(root)

  test "without task pragma, scope is lost after await (regression baseline)":
    let b = Box()

    proc inner(b: Box) {.async.} =
      b.before = currentScope
      await sleepAsync(2.milliseconds)
      b.after = currentScope

    let root = createRoot:
      discard
    withScope(root):
      let m = spawn inner(b)
      waitFor m.future

    check b.before != nil
    check b.after != b.before    # confirms the bug shape

    dispose(root)

  test "scope survives multiple awaits":
    let b = Box()

    proc inner(b: Box) {.task, async.} =
      b.scopes.add currentScope
      await sleepAsync(1.milliseconds)
      b.scopes.add currentScope
      await sleepAsync(1.milliseconds)
      b.scopes.add currentScope

    let root = createRoot:
      discard
    withScope(root):
      let m = spawn inner(b)
      waitFor m.future

    check b.scopes.len == 3
    check b.scopes[0] != nil
    check b.scopes[1] == b.scopes[0]
    check b.scopes[2] == b.scopes[0]
    dispose(root)

  test "value-returning await preserves both result and context":
    let b = Box()

    proc produce(): Future[int] {.async.} =
      await sleepAsync(1.milliseconds)
      return 42

    proc inner(b: Box) {.task, async.} =
      b.got = await produce()
      b.after = currentScope

    let root = createRoot:
      discard
    withScope(root):
      let m = spawn inner(b)
      waitFor m.future

    check b.got == 42
    check b.after != nil
    dispose(root)

  test "withContext block restores threadvars for callback code":
    let root = createRoot:
      discard
    var ctx: TaskContext
    withScope(root):
      ctx = captureContext()
    # Outside the withScope, currentScope is not root.
    let outerBefore = currentScope
    check outerBefore != root
    var seen: Scope
    withContext(ctx):
      seen = currentScope
    check seen == root
    check currentScope == outerBefore   # restored after block
    dispose(root)
