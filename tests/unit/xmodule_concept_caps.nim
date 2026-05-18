## Cross-module user-cap helper for the μb concept-discharge tests.
## Declares a cap with `cap T` and a task that needs it. The importer
## (test_capconcept_xmodule) builds a `staticSupervisor:` that
## discharges this task — proves user caps cross module boundaries
## without registerCap / bitmap encoding.

import fresco/reactive/capabilities

cap CrossModCap

proc crossModTask*() {.needs: CrossModCap.} = discard

var helperCalls* = 0
  ## Counter so a caller can prove the helper actually ran (not just
  ## type-checked).

# Library-helper pattern: a generic proc declared in a different module,
# constrained by a `Grants*` concept. Callers in any module pass any
# supervisor whose type satisfies the concept; mismatches are a
# compile-time error at the *call site* (the use case that motivated
# μb). The proc isn't itself a fresco task — it's library code that
# operates on the supervisor handed to it.
proc helperNeedingCrossMod*[S: GrantsCrossModCap](sup: S): int =
  inc helperCalls
  result = helperCalls
