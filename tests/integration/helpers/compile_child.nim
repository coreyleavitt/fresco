## compile_child.nim — shared child-binary compilation helper for tier-2
## PTY signal tests.
##
## Provides `compileChildBinary(srcRelToHelpers, outBin)`:
##   - derives absolute paths from `currentSourcePath()` so the helper is
##     cwd-independent (M8 portability fix)
##   - passes `-f` to force a fresh recompile so stale binaries cannot
##     mask regressions
##   - returns `(ok: bool, msg: string)` so the caller can `skip()` with
##     a message rather than `doAssert` (which would FAIL instead of SKIP
##     when `nim` is absent)
##
## Usage:
##   import ./helpers/compile_child
##   let (ok, msg) = compileChildBinary("inline_graceful_child.nim",
##                                      "/tmp/fresco_inline_graceful_child")
##   if not ok:
##     skip()

import std/[os, osproc]

const HelpersDir = currentSourcePath().splitPath.head
  ## Absolute path to tests/integration/helpers/ — stable regardless of cwd.

const SrcDir = HelpersDir / ".." / ".." / ".." / "src"
  ## Absolute path to fresco/src — passed to nim as --path so imports resolve.

proc compileChildBinary*(srcFilename: string, outBin: string):
    tuple[ok: bool, msg: string] =
  ## Compile `srcFilename` (a basename relative to the helpers/ directory)
  ## into `outBin`. Uses absolute paths and -f to guarantee a fresh build.
  ## Returns (true, "") on success; (false, errorMsg) on failure.
  let srcAbs = HelpersDir / srcFilename
  let srcDir = HelpersDir / ".." / ".." / ".." / "src"
  let cmd = "nim c --hints:off --warnings:off -f --path:" &
            srcDir & " -o:" & outBin & " " & srcAbs
  let (output, exitCode) = execCmdEx(cmd)
  if exitCode == 0:
    (true, "")
  else:
    (false, "compile failed (exit " & $exitCode & "): " & output)
