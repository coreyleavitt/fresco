import std/unittest
import fresco/reactive/scope
import fresco/reactive/context

type
  ModelClient = ref object
    apiKey: string
  Theme = ref object
    accent: string
  Logger = ref object
    name: string

suite "provide / use":

  test "provide in current scope; use retrieves it":
    let root = createRoot:
      provide ModelClient(apiKey: "k1")
    withScope(root):
      let mc = use ModelClient
      check mc.apiKey == "k1"
    dispose(root)

  test "use raises when no ancestor provides T":
    let root = createRoot:
      provide ModelClient(apiKey: "k1")
    withScope(root):
      expect MissingProviderError:
        discard use Theme
    dispose(root)

  test "tryUse returns nil when no provider":
    let root = createRoot:
      provide ModelClient(apiKey: "k1")
    withScope(root):
      check tryUse(Theme) == nil
      check tryUse(ModelClient) != nil
    dispose(root)

  test "child scope inherits ancestor's providers":
    let outer = newScope()
    withScope(outer):
      provide ModelClient(apiKey: "outer")
    let inner = newScope(outer)
    withScope(inner):
      let mc = use ModelClient
      check mc.apiKey == "outer"
    dispose(outer)

  test "child scope can shadow with its own provider":
    let outer = newScope()
    withScope(outer):
      provide ModelClient(apiKey: "outer")
    let inner = newScope(outer)
    withScope(inner):
      provide ModelClient(apiKey: "inner")
      let mc = use ModelClient
      check mc.apiKey == "inner"
    # Outer scope still sees outer value.
    withScope(outer):
      let mc = use ModelClient
      check mc.apiKey == "outer"
    dispose(outer)

  test "multiple distinct types coexist":
    let root = newScope()
    withScope(root):
      provide ModelClient(apiKey: "k")
      provide Theme(accent: "blue")
      provide Logger(name: "main")
    withScope(root):
      check (use ModelClient).apiKey == "k"
      check (use Theme).accent == "blue"
      check (use Logger).name == "main"
    dispose(root)

  test "innermost-last provider wins on duplicates within same scope":
    let root = newScope()
    withScope(root):
      provide ModelClient(apiKey: "first")
      provide ModelClient(apiKey: "second")
      let mc = use ModelClient
      check mc.apiKey == "second"
    dispose(root)

  test "use outside any scope raises":
    expect MissingProviderError:
      discard use ModelClient

  test "typeMarker produces distinct keys for distinct types":
    # Regression for review #18: previously providers were keyed on
    # `$T` (the type name as a string), so two `Config` types declared
    # in different modules would silently collide. typeMarker gives
    # one {.global.} ref per type instantiation, so the keys differ.
    check typeMarker(ModelClient) != typeMarker(Theme)
    check typeMarker(ModelClient) == typeMarker(ModelClient)   # stable
