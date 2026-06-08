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
