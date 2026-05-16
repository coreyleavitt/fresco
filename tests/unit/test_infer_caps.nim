## Capability AST inference via `{.inferCaps.}` pragma (#52).
##
## Inference is a heuristic convenience layer on top of C1's manual
## `{.needs.}` discharge. It walks the proc body for calls to known
## primitives (readFile → FsReadCap, etc.) and unions the matching
## caps into the same `procRequiresTable` entry that manual
## annotations write to. Limitation: matching is `repr`-based, so
## aliased / wrapped primitives are NOT detected — the user falls
## back to manual `{.needs.}` for those cases.

import std/[macros, os, osproc, tables, unittest]
import fresco/reactive/capabilities
import fresco/reactive/capset

# Stub for `connect`: the chronos one is overloaded with many arg
# shapes; the inference walker only cares about the rightmost ident
# of the callee, so a local stub is enough to exercise the match.
proc connect(host: string, port: int) = discard

# Helper that exposes the CT table to runtime tests via a macro.
# (The pragma writes to procRequiresTable in a static: block at
# compile time; this helper extracts the value into a const so the
# test can assert against it.)
macro requiresOf(name: static[string]): CapSet =
  ## Emit a CapSet literal — hand-built since `distinct array`
  ## doesn't pass through `newLit`.
  let s =
    if name in procRequiresTable: procRequiresTable[name]
    else: EmptyCaps
  var arr = newNimNode(nnkBracket)
  for w in s.words: arr.add newLit(w)
  newCall(bindSym"CapSet", arr)

suite "inferCaps: primitive detection":

  test "readFile call → FsReadCap in procRequiresTable":
    proc loadConfig() {.inferCaps.} =
      discard readFile("conf.toml")
    check requiresOf("loadConfig").contains(ckFsRead)

  test "multiple distinct primitives → multiple caps inferred":
    proc fetchAndCache() {.inferCaps.} =
      let data = readFile("input.txt")
      writeFile("cache.bin", data)
      discard execShellCmd("post-process cache.bin")
    let s = requiresOf("fetchAndCache")
    check s.contains(ckFsRead)
    check s.contains(ckFsWrite)
    check s.contains(ckProcess)

  test "no primitives → empty cap set (no false positives)":
    proc pureWork() {.inferCaps.} =
      var x = 0
      for i in 1 .. 10: x += i
      discard x
    check requiresOf("pureWork") == EmptyCaps

  test "{.needs.} + {.inferCaps.} compose as union":
    # Manual needs FsReadCap; body writes a file → union should
    # include both FsReadCap (manual) and FsWriteCap (inferred).
    proc mixedTask() {.needs: FsReadCap, inferCaps.} =
      writeFile("out.log", "stamp")
    let s = requiresOf("mixedTask")
    check s.contains(ckFsRead)        # from manual
    check s.contains(ckFsWrite)       # from inference

  test "discharge: missing inferred cap → staticSupervisor compile error":
    proc needsNetwork() {.inferCaps.} =
      connect("example.com", 80)
    # Sanity: inference recorded the cap.
    check requiresOf("needsNetwork").contains(ckNetwork)
    # Supervisor that doesn't provide NetworkCap → discharge fails.
    check not compiles(
      block:
        let sup = staticSupervisor:
          provides(FsReadCap)        # NetworkCap missing
          child needsNetwork
        sup)

  test "aliased primitive call is NOT detected (documented limit)":
    # The user assigns `readFile` to a local, then calls through the
    # local. AST walks see `myRead(...)` whose callee.repr is "myRead",
    # not "readFile", so the inference table doesn't match.
    proc aliasedRead() {.inferCaps.} =
      let myRead = readFile
      discard myRead("conf.toml")
    # No cap inferred — this is the documented heuristic limit.
    check requiresOf("aliasedRead") == EmptyCaps
