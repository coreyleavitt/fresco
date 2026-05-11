## Typed dynamically-scoped context: `provide T: value` / `use T`.
##
## A `provide` deposits a value into the current scope under its type
## name; `use T` walks up the scope chain (innermost first) and returns
## the nearest match. A child scope's `provide` shadows an ancestor's
## of the same type.
##
## v2.0 runtime version: `provide` and `use` accept `ref` types only,
## stored as `RootRef` with type-name string keys. Value-type support
## and compile-time discharge along static supervisor paths come in
## v2.4 (see DESIGN.md R14).

import ./scope

type
  MissingProviderError* = object of CatchableError

proc provide*[T: ref](value: T) =
  ## Install `value` in the current scope. No-op outside any scope.
  ## The captured-by-closure reference keeps `value` alive for the
  ## scope's lifetime.
  if currentScope == nil or currentScope.disposed: return
  let captured = value
  currentScope.providers.add ProviderEntry(
    typeName: $T,
    fetch: proc(): pointer = cast[pointer](captured))

proc use*[T: ref](_: typedesc[T]): T =
  ## Walk up the scope chain; return the most-recently provided value
  ## of type T. Raises MissingProviderError if no ancestor provides one.
  let key = $T
  var s = currentScope
  while s != nil:
    for i in countdown(s.providers.high, 0):
      if s.providers[i].typeName == key:
        return cast[T](s.providers[i].fetch())
    s = s.parent
  raise newException(MissingProviderError,
    "no provider for " & key & " in current scope chain")

proc tryUse*[T: ref](_: typedesc[T]): T =
  ## Same as `use(T)` but returns nil instead of raising.
  let key = $T
  var s = currentScope
  while s != nil:
    for i in countdown(s.providers.high, 0):
      if s.providers[i].typeName == key:
        return cast[T](s.providers[i].fetch())
    s = s.parent
  return nil
