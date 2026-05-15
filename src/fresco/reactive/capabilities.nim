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

# --- {.requires: A, B.} pragma -------------------------------------------

var procRequiresTable* {.compileTime.}: Table[string, CapSet]
  ## Module-local CT table: maps a proc's symbol name to the `CapSet`
  ## declared via `{.requires: ...}`. Read by the `staticSupervisor:`
  ## DSL during discharge. **Per-module** — tasks and the supervisor
  ## registering them must live in the same compilation unit for C1
  ## discharge. Cross-module discovery is tracked at #53.

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

proc capBitForName(name: string, ctx: NimNode): CapSet =
  case name
  of "FsReadCap":   capBit(ckFsRead)
  of "FsWriteCap":  capBit(ckFsWrite)
  of "ProcessCap":  capBit(ckProcess)
  of "NetworkCap":  capBit(ckNetwork)
  of "TerminalCap": capBit(ckTerminal)
  of "StateMutCap": capBit(ckStateMut)
  else:
    error("unknown capability type `" & name &
          "` — expected one of FsReadCap, FsWriteCap, " &
          "ProcessCap, NetworkCap, TerminalCap, StateMutCap", ctx)
    0'u64

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
  ## Stashes the bit-encoded `CapSet` in `procRequiresTable` keyed
  ## by proc name. The `staticSupervisor:` DSL reads from this table
  ## during compile-time discharge.
  var bits: CapSet = 0
  # `caps` is either a single ident (one cap) or a TupleConstr / Par
  # node holding multiple caps. Normalize to a flat seq.
  var capNodes: seq[NimNode] = @[]
  if caps.kind in {nnkTupleConstr, nnkPar, nnkBracket}:
    for c in caps: capNodes.add c
  else:
    capNodes.add caps
  for c in capNodes:
    bits = bits or capBitForName(c.repr, c)
  let n = nameOfProc(procDef)
  if n.len > 0:
    procRequiresTable[n] = bits
  procDef

# --- `staticSupervisor:` DSL ---------------------------------------------

type
  StaticSupervisor*[Provided: static[CapSet]] = ref object
    ## Phantom-typed marker that compile-time discharge has succeeded.
    ## `Provided` is the bit-encoded set of capabilities the
    ## supervisor (and any ancestor) makes available to its children.
    ## A `child factory` registration only compiles when the
    ## factory's `{.requires: ...}` CapSet is a subset of `Provided`.

proc capSetFromTypeNames(caps: NimNode): CapSet =
  ## Compile-time helper: walk a list of cap-type idents and OR
  ## their bits into a `CapSet`. Unknown names produce `error()`.
  for c in caps:
    result = result or capBitForName(c.repr, c)

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

proc dischargeSupervisorBlock(body: NimNode, ancestorProvides: CapSet) =
  ## Walk a supervisor body, accumulate `provides`, discharge each
  ## `child` against (ancestorProvides ∪ local provides), and recurse
  ## into nested `supervisor:` blocks. Compile-time only; emits
  ## macro `error()` on missing-cap.
  var localProvides: CapSet = 0
  # Two passes: first collect all `provides(...)` so order within a
  # block doesn't matter (children can come before `provides` lines
  # and still see them). This matches the spirit of "supervisor
  # topology is declarative."
  for stmt in body:
    if stmt.kind == nnkCall and stmt[0].kind == nnkIdent and
       stmt[0].strVal == "provides" and stmt.len >= 2:
      var caps = newTree(nnkBracket)
      for i in 1 ..< stmt.len: caps.add stmt[i]
      localProvides = localProvides or capSetFromTypeNames(caps)
  let effective = ancestorProvides or localProvides
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
      let required = procRequiresTable[name]
      if not required.isSubsetOf(effective):
        let missingBits = missing(required, effective)
        error("`child " & name & "`: required capabilities " &
              renderCapSet(required) & " not satisfied by supervisor's " &
              "provides " & renderCapSet(effective) &
              " — missing: " & renderCapSet(missingBits), fac)
    elif stmt.kind == nnkCall and stmt[0].kind == nnkIdent and
         stmt[0].strVal == "supervisor" and stmt.len >= 2 and
         stmt[1].kind == nnkStmtList:
      # Nested `supervisor:` block — recurse with effective as the
      # new ancestorProvides.
      dischargeSupervisorBlock(stmt[1], effective)

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
  var topProvides: CapSet = 0
  for stmt in body:
    if stmt.kind == nnkCall and stmt[0].kind == nnkIdent and
       stmt[0].strVal == "provides" and stmt.len >= 2:
      var caps = newTree(nnkBracket)
      for i in 1 ..< stmt.len: caps.add stmt[i]
      topProvides = topProvides or capSetFromTypeNames(caps)
  dischargeSupervisorBlock(body, 0'u64)
  let providedLit = newLit(topProvides)
  result = quote do:
    StaticSupervisor[`providedLit`]()

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
