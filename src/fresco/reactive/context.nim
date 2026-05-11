## Typed dynamically-scoped context: `provide T: value` / `use T`.
##
## A `provide` deposits a value into the current scope under a unique
## key derived from `T`; `use T` walks up the scope chain (innermost
## first) and returns the nearest match. A child scope's `provide`
## shadows an ancestor's of the same type.
##
## Keys are *type-identity-based*, not name-based: two `Config` types
## declared in different modules collide if you key on `$T`. We use a
## per-type-instantiation `{.global.}` sentinel ref whose address is
## the lookup key — each typedesc gets its own.
##
## v2.0 runtime version: `provide` / `use` accept `ref` types only.
## Compile-time discharge along static supervisor paths (DESIGN.md
## R14) lands in v3 — see issue #35.

import ./scope

type
  MissingProviderError* = object of CatchableError

  TypeMarkerObj = ref object
    discard

proc typeMarker*[T](_: typedesc[T]): pointer =
  ## Stable unique key per type T. The `{.global.}` storage gives one
  ## ref per instantiation of this generic — different `T`s get
  ## different markers regardless of `$T` collisions. Pre-warm from a
  ## single thread before multi-thread use (lazy init isn't atomic).
  var marker {.global.}: TypeMarkerObj
  if marker == nil: marker = TypeMarkerObj()
  cast[pointer](marker)

proc provide*[T: ref](value: T) =
  ## Install `value` in the current scope. No-op outside any scope.
  ## The captured-by-closure reference keeps `value` alive for the
  ## scope's lifetime.
  if currentScope == nil or currentScope.disposed: return
  let captured = value
  currentScope.providers.add ProviderEntry(
    typeKey: typeMarker(T),
    fetch: proc(): pointer = cast[pointer](captured))

proc use*[T: ref](_: typedesc[T]): T =
  ## Walk up the scope chain; return the most-recently provided value
  ## of type T. Raises MissingProviderError if no ancestor provides one.
  let key = typeMarker(T)
  var s = currentScope
  while s != nil:
    for i in countdown(s.providers.high, 0):
      if s.providers[i].typeKey == key:
        return cast[T](s.providers[i].fetch())
    s = s.parent
  raise newException(MissingProviderError,
    "no provider for type " & $T & " in current scope chain")

proc tryUse*[T: ref](_: typedesc[T]): T =
  ## Same as `use(T)` but returns nil instead of raising.
  let key = typeMarker(T)
  var s = currentScope
  while s != nil:
    for i in countdown(s.providers.high, 0):
      if s.providers[i].typeKey == key:
        return cast[T](s.providers[i].fetch())
    s = s.parent
  return nil
