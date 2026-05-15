## Capability markers and the `requires` annotation.
##
## Capabilities are opaque ref types that travel through the existing
## `provide T: v` / `use T` substrate. A capability is *granted* by
## providing its marker somewhere up the scope chain; a task that
## needs the capability calls `use FsReadCap` (or uses the `requires`
## macro), which raises MissingProviderError if no ancestor granted it.
##
##   # at app root, somewhere up the supervisor chain:
##   provide FsReadCap(),  provide ProcessCap()
##
##   # in a task that touches the filesystem:
##   task readConfig() =
##     assertCap(FsReadCap)         # ← runtime check; raises if missing
##     let data = readFile("conf.toml")
##     ...
##
## Standard markers cover the broad axes of dangerous side effects:
## filesystem reads/writes, process spawning, network access, terminal
## I/O, mutable state. Apps can declare their own markers the same
## way (any `ref object` works as a capability).
##
## v2.4 ships the runtime-checked layer using the existing `provide`/
## `use` machinery — no separate cap registry. Future work: a typed
## macro that walks task bodies, identifies primitive uses (readFile,
## openProcess, etc.), and *automatically* emits the matching
## `requires` annotations. That would lift the check from runtime to
## compile time along statically-known supervisor paths.

import std/[macros, strutils, tables]
import ./context
import ./capset

type
  FsReadCap*    = ref object   ## read from local filesystem
  FsWriteCap*   = ref object   ## write to local filesystem
  ProcessCap*   = ref object   ## spawn / exec OS processes
  NetworkCap*   = ref object   ## socket / DNS / HTTP
  TerminalCap*  = ref object   ## raw-mode TTY I/O (implicit for UI tasks)
  StateMutCap*  = ref object   ## mutate reactive state (implicit for reactive tasks)

# --- Compile-time cap-type → CapKind mapping -----------------------------
#
# The compile-time discharge layer (#35 C1) operates on `CapSet` bit
# values, not on the ref-object marker types. This block defines the
# bidirectional mapping between the two — the marker types remain the
# user-facing surface (`requires: FsReadCap, NetworkCap`); the bit
# values are internal plumbing for type identity of `StaticSupervisor`.

func capKindFor*(_: typedesc[FsReadCap]):   CapKind = ckFsRead
func capKindFor*(_: typedesc[FsWriteCap]):  CapKind = ckFsWrite
func capKindFor*(_: typedesc[ProcessCap]):  CapKind = ckProcess
func capKindFor*(_: typedesc[NetworkCap]):  CapKind = ckNetwork
func capKindFor*(_: typedesc[TerminalCap]): CapKind = ckTerminal
func capKindFor*(_: typedesc[StateMutCap]): CapKind = ckStateMut

# --- User-defined capability registration (#54) --------------------------

var nextUserSlot {.compileTime.}: int = ord(ckUser0)
  ## Monotonic per-module counter. Advances by 1 on each
  ## `registerCap T` call. Slot exhaustion past `ckUser57` is a
  ## compile error. Cross-module slot stability tracked at #53.

var registeredCapTypes {.compileTime.}: seq[string]
  ## Stable line-info keys (filename:line:col) of types passed to
  ## `registerCap`. Used to detect duplicate registration with a
  ## clearer error than Nim's native "redefinition of capKindFor."

macro registerCap*(T: typed): untyped =
  ## Allocate the next free `ckUserN` slot for the user-defined
  ## capability type `T`, and emit a `capKindFor(_: typedesc[T]):
  ## CapKind` overload mapping `T` to that slot. After this call,
  ## `{.needs: T.}` and `provides(T)` work just like for the
  ## built-in capability markers.
  ##
  ## Usage:
  ##
  ##   type MyCap = ref object
  ##   registerCap MyCap
  ##   proc myTask() {.needs: MyCap.} = ...
  ##
  ## Slot allocation is **monotonic per module**: the order of
  ## `registerCap` calls determines which slot each type claims.
  ## Cross-module sharing is constrained by the per-module CT
  ## state — module B can't see slots claimed in module A unless
  ## both go through a shared registry (see #53).
  # Key by type's repr — within a single module Nim guarantees
  # distinct types have distinct names, so two `registerCap T`
  # calls with the same `T.repr` are by definition the same type.
  # (Cross-module distinct-but-same-named types would alias under
  # this key, but cross-module registration isn't supported in C1
  # anyway — see #53.) `lineInfoObj` on a typed parameter points
  # back into the macro's call site, not the user's `type` line,
  # so it doesn't give a useful diagnostic location.
  let key = T.repr
  if key in registeredCapTypes:
    error("registerCap: type `" & key & "` is already registered " &
          "— each capability type may be registered at most once " &
          "per compilation unit", T)
  if nextUserSlot > ord(ckUser57):
    error("registerCap: all 58 ckUserN slots are exhausted — " &
          "this module has registered too many user capabilities " &
          "(built-in caps occupy ckFsRead..ckStateMut; the bitmap " &
          "ceiling is 64 bits)", T)
  registeredCapTypes.add key
  let slot = CapKind(nextUserSlot)
  inc nextUserSlot
  let slotLit = newLit(slot)
  result = quote do:
    func capKindFor*(_: typedesc[`T`]): CapKind = `slotLit`

# --- {.requires: A, B.} pragma -------------------------------------------

var procRequiresTable* {.compileTime.}: Table[string, CapSet]
  ## Module-local CT table: maps a proc's symbol name to the `CapSet`
  ## declared via `{.requires: ...}`. Read by the `staticSupervisor:`
  ## DSL during discharge. **Per-module** — tasks and the supervisor
  ## registering them must live in the same compilation unit for C1
  ## discharge. Cross-module discovery is tracked at #53.

proc setProcRequires*(name: string, bits: CapSet) {.compileTime.} =
  ## CT helper for the `{.needs.}` pragma's emitted static block.
  ## Wraps the Table assignment so user code doesn't need to import
  ## `std/tables` to use the pragma.
  procRequiresTable[name] = bits

proc nameOfProc(procDef: NimNode): string =
  ## Extract the user-visible name of a proc declaration, handling
  ## the cases macro-pragmas encounter: nnkProcDef / nnkFuncDef /
  ## nnkMethodDef / nnkLambda / nnkIteratorDef.
  if procDef.len > 0 and procDef[0].kind in {nnkIdent, nnkSym, nnkPostfix}:
    let head = procDef[0]
    if head.kind == nnkPostfix and head.len >= 2: head[1].strVal
    else: head.strVal
  else:
    ""

proc capNodesOf(caps: NimNode): seq[NimNode] =
  ## Flatten a pragma/DSL argument that may be a single ident, a
  ## tuple/par construct holding several idents, or a bracket
  ## literal. Used by both `needs` and `provides(...)` parsing.
  if caps.kind in {nnkTupleConstr, nnkPar, nnkBracket}:
    for c in caps: result.add c
  else:
    result.add caps

proc bitsExpr(capNodes: seq[NimNode]): NimNode =
  ## Build the AST for `capBit(capKindFor(T0)) or capBit(capKindFor(T1)) or ...`
  ## — defers cap-name resolution to Nim's overload-resolution on
  ## `capKindFor`, so any user-registered cap with a `capKindFor`
  ## overload in scope works without special-casing in the macros.
  if capNodes.len == 0: return newLit(0'u64)
  result = nil
  for c in capNodes:
    let term = quote do:
      capBit(capKindFor(`c`))
    if result == nil: result = term
    else: result = infix(result, "or", term)

macro needs*(caps, procDef: untyped): untyped =
  ## **Macro pragma** attaching a compile-time required-capability
  ## set to a proc declaration. Used with the tuple form so multiple
  ## caps can ride the single-argument pragma slot Nim provides:
  ##
  ##   proc agentLoop() {.needs: (FsReadCap, NetworkCap).} =
  ##     ...
  ##   proc fsTask()   {.needs: FsReadCap.} =        # single cap, no parens
  ##     ...
  ##
  ## Named `needs` (not `requires`) because `requires` is reserved
  ## by Nim's built-in contract pragmas and would silently shadow.
  ##
  ## The macro emits a `static:` block that computes the bit-encoded
  ## `CapSet` via `capBit(capKindFor(T))` for each cap and writes it
  ## into `procRequiresTable`. Resolution of `capKindFor(T)` happens
  ## via Nim's overload resolution, so any user type with a
  ## `capKindFor` overload in scope (typically via `registerCap T`)
  ## works without changes to this macro.
  let capNodes = capNodesOf(caps)
  let n = nameOfProc(procDef)
  if n.len == 0: return procDef
  let nameLit = newLit(n)
  let bitsAst = bitsExpr(capNodes)
  result = newStmtList(
    nnkStaticStmt.newTree(
      newStmtList(
        newCall(bindSym"setProcRequires", nameLit, bitsAst))),
    procDef)

# --- `staticSupervisor:` DSL ---------------------------------------------

type
  StaticSupervisor*[Provided: static[CapSet]] = ref object
    ## Phantom-typed marker that compile-time discharge has succeeded.
    ## `Provided` is the bit-encoded set of capabilities the
    ## supervisor (and any ancestor) makes available to its children.
    ## A `child factory` registration only compiles when the
    ## factory's `{.requires: ...}` CapSet is a subset of `Provided`.

proc provideBitsExpr(caps: NimNode): NimNode =
  ## Compile-time helper: build the AST for the bit-OR expression
  ## representing a `provides(A, B, ...)` cap list. Same overload-
  ## resolution path as `bitsExpr` — works for built-ins and any
  ## type with a `capKindFor` overload.
  bitsExpr(capNodesOf(caps))

proc renderCapName(k: CapKind): string =
  case k
  of ckFsRead:    "FsReadCap"
  of ckFsWrite:   "FsWriteCap"
  of ckProcess:   "ProcessCap"
  of ckNetwork:   "NetworkCap"
  of ckTerminal:  "TerminalCap"
  of ckStateMut:  "StateMutCap"
  else:           $k

proc renderCapSet(s: CapSet): string =
  var parts: seq[string] = @[]
  for k in CapKind:
    if k in s: parts.add renderCapName(k)
  if parts.len == 0: "{}"
  else: "{" & parts.join(", ") & "}"

proc collectProvidesExprs(body: NimNode): seq[NimNode] =
  ## Walk a supervisor body and return the NimNode expressions
  ## representing each `provides(A, B, ...)` declaration. The
  ## bit-OR composition happens later, in emitted code, so user
  ## caps flow through Nim's overload resolution on `capKindFor`.
  for stmt in body:
    if stmt.kind == nnkCall and stmt[0].kind == nnkIdent and
       stmt[0].strVal == "provides" and stmt.len >= 2:
      var caps = newTree(nnkBracket)
      for i in 1 ..< stmt.len: caps.add stmt[i]
      result.add provideBitsExpr(caps)

proc orAll(exprs: openArray[NimNode]): NimNode =
  ## Build the AST for `a or b or c or ...` over a list of expressions.
  if exprs.len == 0: return newLit(0'u64)
  result = exprs[0]
  for i in 1 ..< exprs.len:
    result = infix(result, "or", exprs[i])

proc dischargeSupervisorBlock(body, ancestorProvidedExpr: NimNode,
                              checks: var seq[NimNode]) =
  ## Walk a supervisor body, build the effective `provided` AST
  ## (ancestor + local), and emit per-child `when` checks that
  ## fail at compile time with a readable message if discharge
  ## fails. Recurses into nested `supervisor:` blocks.
  ##
  ## The discharge check is deferred to emitted code (a `static:`
  ## block) because user-registered cap types need Nim's overload
  ## resolution on `capKindFor` — that resolution happens during
  ## sem of the emitted code, not at macro-expansion time.
  let localProvidedExprs = collectProvidesExprs(body)
  var combined: seq[NimNode]
  combined.add ancestorProvidedExpr
  for e in localProvidedExprs: combined.add e
  let effectiveExpr = orAll(combined)
  for stmt in body:
    if stmt.kind in {nnkCommand, nnkCall} and
       stmt[0].kind == nnkIdent and stmt[0].strVal == "child" and
       stmt.len >= 2:
      let fac = stmt[1]
      let name = fac.repr
      if name notin procRequiresTable:
        error("`child " & name & "`: factory has no {.needs: ...} " &
              "annotation — every staticSupervisor child must declare " &
              "its capability set explicitly (use {.needs: <caps>.} " &
              "on the proc, or {.needs: ().} for no caps)", fac)
      # The required CapSet is already a known value at this point
      # (the `static:` block from `{.needs.}` ran during sem in
      # declaration order, before the staticSupervisor macro). Emit
      # a CT discharge check against the provided expression.
      let requiredLit = newLit(procRequiresTable[name])
      let nameLit = newLit(name)
      checks.add quote do:
        when not isSubsetOf(`requiredLit`, `effectiveExpr`):
          {.error: "fresco capability discharge failed for `child " &
                   `nameLit` & "`: required " & renderCapSet(`requiredLit`) &
                   ", provides " &
                   renderCapSet(`effectiveExpr`) & ", missing " &
                   renderCapSet(missing(`requiredLit`, `effectiveExpr`)) &
                   " — add the missing caps to a `provides(...)` line " &
                   "in this supervisor or an ancestor.".}
    elif stmt.kind == nnkCall and stmt[0].kind == nnkIdent and
         stmt[0].strVal == "supervisor" and stmt.len >= 2 and
         stmt[1].kind == nnkStmtList:
      dischargeSupervisorBlock(stmt[1], effectiveExpr, checks)

macro staticSupervisor*(body: untyped): untyped =
  ## Declarative supervisor DSL. Recognized forms inside the block:
  ##
  ##   provides(FsReadCap, NetworkCap)        # capability declaration
  ##   child agentLoop                        # task registration
  ##   supervisor:                            # nested subtree; sees
  ##     provides(TerminalCap)                #   ancestor + local provides
  ##     child uiLoop
  ##
  ## Discharge: every `child` factory must have a `{.needs: ...}`
  ## annotation, and its required `CapSet` must be a subset of the
  ## (ancestor ∪ local) provided `CapSet`. Failure → compile error
  ## with the missing caps named.
  ##
  ## Returns a `StaticSupervisor[Provided]` value parameterized on
  ## the **top-level** provided set. For now a phantom marker —
  ## wiring up the runtime supervisor's `addChild` calls comes after
  ## discharge is solid.
  # Top-level provides expression — bit-OR of every `provides(...)`
  # at the outermost scope. Used to parameterize the returned
  # `StaticSupervisor[Provided]`. Computed via the same deferred-
  # NimNode pattern as discharge: we don't have the capKindFor
  # results at macro-time, so we emit the expression and let Nim
  # sem-evaluate it for both the discharge `when` checks and the
  # generic parameter.
  let topProvidedExpr = orAll(collectProvidesExprs(body))
  var checks: seq[NimNode] = @[]
  dischargeSupervisorBlock(body, newLit(0'u64), checks)
  result = newStmtList()
  for c in checks: result.add c
  result.add quote do:
    StaticSupervisor[static(`topProvidedExpr`)]()

macro assertCap*(caps: varargs[untyped]): untyped =
  ## Runtime assertion that every capability in `caps` is provided by
  ## some ancestor scope. Each cap expands to a `discard use(Cap)`
  ## which raises `MissingProviderError` if missing.
  ##
  ## `assertCap` is the runtime-checked fallback. The compile-time
  ## form is `{.requires: ...}` (see `capset.nim` and the
  ## `staticSupervisor:` DSL in #35 C1) which discharges along a
  ## statically-known supervisor topology and fails with a compile
  ## error rather than a runtime exception. Use the pragma form
  ## whenever the supervisor is statically declared; use `assertCap`
  ## inside dynamically-spawned code or to double-check at task entry.
  ##
  ## Renamed from `requires` to free that name for the compile-time
  ## pragma. The runtime semantics are unchanged.
  result = newStmtList()
  for cap in caps:
    result.add quote do:
      discard use(`cap`)
