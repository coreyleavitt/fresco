import std/unittest
import fresco/reactive/scope
import fresco/reactive/context
import fresco/reactive/capabilities

suite "capabilities":

  test "providing a cap satisfies a single requires":
    let root = newScope()
    withScope(root):
      provide FsReadCap()
    let child = newScope(root)
    withScope(child):
      # Should not raise.
      requires(FsReadCap)
    dispose(root)

  test "missing cap raises MissingProviderError":
    let root = newScope()
    withScope(root):
      provide FsReadCap()
    withScope(root):
      expect MissingProviderError:
        requires(FsWriteCap)
    dispose(root)

  test "requires accepts multiple caps":
    let root = newScope()
    withScope(root):
      provide FsReadCap()
      provide NetworkCap()
      provide ProcessCap()
    withScope(root):
      requires(FsReadCap, NetworkCap, ProcessCap)
    dispose(root)

  test "first missing cap among many raises":
    let root = newScope()
    withScope(root):
      provide FsReadCap()
      # NetworkCap not provided
      provide ProcessCap()
    withScope(root):
      expect MissingProviderError:
        requires(FsReadCap, NetworkCap, ProcessCap)
    dispose(root)

  test "child scope can grant additional caps not in parent":
    let outer = newScope()
    withScope(outer):
      provide FsReadCap()
    let inner = newScope(outer)
    withScope(inner):
      provide NetworkCap()
      requires(FsReadCap, NetworkCap)   # inherits + adds
    # Back in outer scope, NetworkCap is gone.
    withScope(outer):
      expect MissingProviderError:
        requires(NetworkCap)
    dispose(outer)
