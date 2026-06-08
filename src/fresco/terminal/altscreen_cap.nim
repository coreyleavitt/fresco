## AltScreenCap — compile-time capability token for alternate-screen support.
##
## Represents "this terminal supports the alternate screen buffer"
## (DECSET ?1049h / DECRST ?1049l). Declared via intonaco's `cap` macro so it
## participates in the full `supervisor:` / `{.needs.}` / `provides`
## discharge system.
##
## Later work (rfc-terminal-interaction.md) will supersede this with a full
## terminal-capability layer; this module exists so S1 alt-screen slices (5,
## 5b) have a concrete type to reference.
##
## Imports: `intonaco/reactive` re-exports the `cap` macro.

import intonaco/reactive

cap AltScreenCap

# ---------------------------------------------------------------------------
# AltScreenUnsupportedError — raised by acquireAltScreenGrant on absence
# ---------------------------------------------------------------------------

type
  AltScreenUnsupportedError* = object of CatchableError
    ## Raised when a terminal does not support the alternate-screen buffer
    ## (?1049h / ?1049l). Construction of AltScreen[S] requires a grant;
    ## the only outcome on an incapable terminal is this error — never a
    ## silent inline fallback, never an Option the caller can ignore.

  AltScreenCapWitness* = object
    ## A minimal zero-size grant witness: satisfies GrantsAltScreenCap and
    ## is the return type of acquireAltScreenGrant on success.
    ## Callers pass this directly to newAltScreen as the `cap` argument.
    altScreenGrant*: AltScreenGrant

# ---------------------------------------------------------------------------
# Runtime acquisition — placeholder for the future terminal-interaction layer
# ---------------------------------------------------------------------------

proc acquireAltScreenGrant*(supportsAltScreen: bool): AltScreenCapWitness =
  ## Acquire an AltScreenCapWitness from a raw capability signal.
  ##
  ## Returns a witness (satisfying GrantsAltScreenCap) when the terminal
  ## reports alt-screen support; raises AltScreenUnsupportedError otherwise.
  ## There is no silent fallback: a terminal that ignores ?1049h would corrupt
  ## the diff cache by painting absolute coordinates over live scrollback.
  ##
  ## NOTE — placeholder: the `supportsAltScreen: bool` argument is a
  ## stand-in for the not-yet-built terminal-interaction capability layer
  ## (rfc-terminal-interaction.md). When that layer ships, it supersedes
  ## this argument with a real terminal capability signal. The contract —
  ## raise on absent, return witness on present — stays unchanged.
  if not supportsAltScreen:
    raise newException(AltScreenUnsupportedError,
      "alt-screen not supported by this terminal (?1049h ignored); " &
      "construct an InlineScreen instead or run on a capable terminal")
  AltScreenCapWitness()
