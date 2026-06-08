## Slice 5b — capability gate: fail fast, no silent inline fallback.
##
## Verifies that:
##   (a) acquireAltScreenGrant(false) raises AltScreenUnsupportedError
##       — loud failure, never silently downgrades to inline mode.
##   (b) acquireAltScreenGrant(true) returns an AltScreenGrant and
##       newAltScreen can be constructed from it.
##   (c) There is no Option-that-callers-ignore path: the only failure
##       outcome is a raised exception.
##
## The `supportsAltScreen: bool` argument is an explicit placeholder for
## the not-yet-built terminal-interaction cap layer (rfc-terminal-interaction.md).
## When that layer lands, it supersedes this argument with a real terminal
## capability signal; the proc contract (raise on absent, grant on present)
## stays the same.

import std/unittest
import fresco/terminal/altscreen_cap
import fresco/altscreen
import fresco/render/sink/memory

suite "acquireAltScreenGrant: fail-fast capability gate":

  test "raises AltScreenUnsupportedError when terminal does not support alt-screen":
    ## The ONLY outcome on an incapable terminal is a raised error —
    ## never a fallback object, never an Option.
    expect AltScreenUnsupportedError:
      discard acquireAltScreenGrant(false)

  test "returns an AltScreenGrant when terminal supports alt-screen":
    ## Success path: grant comes back, no error.
    let grant = acquireAltScreenGrant(true)
    ## The grant satisfies GrantsAltScreenCap (verified statically).
    static:
      doAssert AltScreenCapWitness is GrantsAltScreenCap

  test "grant from acquireAltScreenGrant lets newAltScreen construct":
    ## End-to-end: acquire grant → build AltScreen — proves the success
    ## path is not dead code.
    let grant = acquireAltScreenGrant(true)
    let sink = newMemorySink()
    let s = newAltScreen(sink, 3, 20, grant)
    check s != nil
    check s.height == 3
    check s.width == 20

  test "no inline fallback: failed acquisition has no usable return value":
    ## Structural: the return type is AltScreenCapWitness, not Option[…].
    ## We confirm this by verifying the raised error is exactly
    ## AltScreenUnsupportedError and the code after the call is unreachable.
    var reached = false
    try:
      discard acquireAltScreenGrant(false)
      reached = true  # must not reach here
    except AltScreenUnsupportedError:
      discard  # correct path
    check not reached
