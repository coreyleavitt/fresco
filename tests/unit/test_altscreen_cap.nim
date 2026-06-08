## Slice 4b — AltScreenCap compile-time capability token.
##
## Verifies that:
##   (a) a witness type carrying the altScreenGrant field satisfies AltScreenCap
##       via GrantsAltScreenCap,
##   (b) an unrelated type does NOT satisfy GrantsAltScreenCap,
##   (c) both assertions hold statically (no runtime surprises).
##
## The `cap` macro is intonaco's mechanism; AltScreenCap is declared in
## fresco/terminal/altscreen_cap.nim and re-exported via fresco/terminal.

import std/unittest
import fresco/terminal/altscreen_cap

suite "altscreen_cap: AltScreenCap compile-time capability token":

  test "a witness carrying AltScreenGrant satisfies GrantsAltScreenCap":
    ## Build a minimal witness type that has the grant field.
    type AltCapWitness = object
      altScreenGrant: AltScreenGrant
    static:
      doAssert AltCapWitness is GrantsAltScreenCap

  test "an unrelated type does NOT satisfy GrantsAltScreenCap":
    ## Soundness: a typo in the witness can't vacuously pass.
    type Unrelated = object
      someField: int
    static:
      doAssert not (Unrelated is GrantsAltScreenCap)

  test "positive and negative witnesses are paired — no vacuous pass":
    ## If AltScreenGrant or GrantsAltScreenCap were undefined this block
    ## wouldn't compile at all, ruling out the vacuous case.
    type GoodWitness = object
      altScreenGrant: AltScreenGrant
    type BadWitness = object
      unrelatedField: string
    static:
      doAssert     GoodWitness is GrantsAltScreenCap
      doAssert not (BadWitness is GrantsAltScreenCap)
