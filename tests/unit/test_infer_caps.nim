## Capability AST inference via `{.inferCaps.}` pragma.
##
## Inference is a heuristic convenience layer over manual `{.needs.}`.
## It walks the proc body for calls to known primitives (readFile →
## FsReadCap, etc.) and unions the matching cap *type names* into the
## same `procRequiresNames` CT store that manual annotations write to.
## Limitation: matching is `repr`-based, so aliased / wrapped
## primitives are NOT detected — the user falls back to manual
## `{.needs.}` for those cases.

import std/[macros, os, osproc, tables, unittest]
import fresco/task/supervisor

# Stub for `connect`: the chronos one is overloaded with many arg
# shapes; the inference walker only cares about the rightmost ident
# of the callee, so a local stub is enough to exercise the match.
proc connect(host: string, port: int) = discard

# Helper that exposes the CT names list to runtime tests via a macro.
# Emits a literal `@[...]` of strings drawn from procRequiresNames
# at macro-expansion time.
macro requiresNamesOf(name: static[string]): seq[string] =
  result = newNimNode(nnkPrefix).add(ident("@"), newNimNode(nnkBracket))
  if name in procRequiresNames:
    for cn in procRequiresNames[name]:
      result[1].add newLit(cn)

suite "inferCaps: primitive detection":

  test "readFile call → FsReadCap in procRequiresNames":
    proc loadConfig() {.inferCaps.} =
      discard readFile("conf.toml")
    check "FsReadCap" in requiresNamesOf("loadConfig")

  test "multiple distinct primitives → multiple caps inferred":
    proc fetchAndCache() {.inferCaps.} =
      let data = readFile("input.txt")
      writeFile("cache.bin", data)
      discard execShellCmd("post-process cache.bin")
    let s = requiresNamesOf("fetchAndCache")
    check "FsReadCap" in s
    check "FsWriteCap" in s
    check "ProcessCap" in s

  test "no primitives → empty cap set (no false positives)":
    proc pureWork() {.inferCaps.} =
      var x = 0
      for i in 1 .. 10: x += i
      discard x
    check requiresNamesOf("pureWork").len == 0

  test "{.needs.} + {.inferCaps.} compose as union":
    # Manual needs FsReadCap; body writes a file → union should
    # include both FsReadCap (manual) and FsWriteCap (inferred).
    proc mixedTask() {.needs: FsReadCap, inferCaps.} =
      writeFile("out.log", "stamp")
    let s = requiresNamesOf("mixedTask")
    check "FsReadCap"  in s    # from manual
    check "FsWriteCap" in s    # from inference

  test "discharge: missing inferred cap → supervisor compile error":
    proc needsNetwork() {.inferCaps.} =
      connect("example.com", 80)
    # Sanity: inference recorded the cap.
    check "NetworkCap" in requiresNamesOf("needsNetwork")
    # Supervisor that doesn't provide NetworkCap → discharge fails.
    check not compiles(
      block:
        let sup = supervisor:
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
    check requiresNamesOf("aliasedRead").len == 0
