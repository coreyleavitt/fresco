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

import std/[macros, strutils, tables, sets]
import ./context

type
  FsReadCap*    = ref object   ## read from local filesystem
  FsWriteCap*   = ref object   ## write to local filesystem
  ProcessCap*   = ref object   ## spawn / exec OS processes
  NetworkCap*   = ref object   ## socket / DNS / HTTP
  TerminalCap*  = ref object   ## raw-mode TTY I/O (implicit for UI tasks)
  StateMutCap*  = ref object   ## mutate reactive state (implicit for reactive tasks)

# --- μb concept-based discharge: grant tokens + Grants* concepts ---------
#
# Each capability has a paired *grant token* (a zero-byte object type)
# and a *Grants concept* matching any supervisor whose object type
# carries the grant field. A supervisor built by `supervisor:` is
# a ref object whose fields are grant tokens, one per cap it provides.
# Discharge at `child` sites is `when typeof(sup) is GrantsX and ...`
# — Nim's concept satisfaction is the subset check, with field-order
# independence as a free property.

type
  FsReadGrant*    = object
  FsWriteGrant*   = object
  ProcessGrant*   = object
  NetworkGrant*   = object
  TerminalGrant*  = object
  StateMutGrant*  = object

  GrantsFsReadCap*   = concept s
    s.fsReadGrant    is FsReadGrant
  GrantsFsWriteCap*  = concept s
    s.fsWriteGrant   is FsWriteGrant
  GrantsProcessCap*  = concept s
    s.processGrant   is ProcessGrant
  GrantsNetworkCap*  = concept s
    s.networkGrant   is NetworkGrant
  GrantsTerminalCap* = concept s
    s.terminalGrant  is TerminalGrant
  GrantsStateMutCap* = concept s
    s.stateMutGrant  is StateMutGrant

type CapMeta* = object
  ## Macro-time metadata for a cap type. Keys: cap's typename as it
  ## appears in source (e.g. "FsReadCap").
  grantField*:  string
  grantType*:   string
  conceptName*: string

var capMetaTable* {.compileTime.}: Table[string, CapMeta]
  ## Compile-time registry of cap → grant-field / grant-type / concept
  ## names. The `supervisor:` macro reads this at expansion time
  ## to build the supervisor object's field list. User caps register
  ## themselves here via `cap T` (added in a later cycle).

static:
  capMetaTable["FsReadCap"]    = CapMeta(grantField: "fsReadGrant",   grantType: "FsReadGrant",   conceptName: "GrantsFsReadCap")
  capMetaTable["FsWriteCap"]   = CapMeta(grantField: "fsWriteGrant",  grantType: "FsWriteGrant",  conceptName: "GrantsFsWriteCap")
  capMetaTable["ProcessCap"]   = CapMeta(grantField: "processGrant",  grantType: "ProcessGrant",  conceptName: "GrantsProcessCap")
  capMetaTable["NetworkCap"]   = CapMeta(grantField: "networkGrant",  grantType: "NetworkGrant",  conceptName: "GrantsNetworkCap")
  capMetaTable["TerminalCap"]  = CapMeta(grantField: "terminalGrant", grantType: "TerminalGrant", conceptName: "GrantsTerminalCap")
  capMetaTable["StateMutCap"]  = CapMeta(grantField: "stateMutGrant", grantType: "StateMutGrant", conceptName: "GrantsStateMutCap")

# --- User-defined capability declaration ---------------------------------

macro cap*(T: untyped): untyped =
  ## Declare a capability type and its concept-discharge metadata.
  ## Emits the cap type (`ref object`), its grant token type
  ## (`<base>Grant`), and the matching `Grants<CapName>` concept,
  ## and registers the cap in `capMetaTable` so `supervisor:`
  ## and `{.needs.}` can resolve it.
  ##
  ## Usage:
  ##   cap MyAppCap
  ##   proc t() {.needs: MyAppCap.} = ...
  ##   let sup = supervisor:
  ##     provides(MyAppCap)
  ##     child t
  ##
  ## Replaces #54's `registerCap`. No slot counter, no enum ceiling —
  ## the cap's identity is its declared type, and concept satisfaction
  ## is the discharge primitive.
  if T.kind notin {nnkIdent, nnkSym}:
    error("cap: expected a single type identifier, got " & $T.kind, T)
  let name = T.strVal
  if name in capMetaTable:
    error("cap: capability `" & name & "` is already declared", T)
  let baseName =
    if name.endsWith("Cap"): name[0 ..< name.len - 3] else: name
  if baseName.len == 0:
    error("cap: capability name `" & name & "` has no body before `Cap` " &
          "suffix — pick a longer name", T)
  let grantTypeName  = baseName & "Grant"
  let conceptName    = "Grants" & name
  let grantFieldName = baseName[0].toLowerAscii & baseName[1 ..< baseName.len] & "Grant"
  capMetaTable[name] = CapMeta(
    grantField:  grantFieldName,
    grantType:   grantTypeName,
    conceptName: conceptName)
  let capIdent    = ident(name)
  let grantIdent  = ident(grantTypeName)
  let conceptId   = ident(conceptName)
  let fieldIdent  = ident(grantFieldName)
  result = quote do:
    type
      `capIdent`*   = ref object
      `grantIdent`* = object
    type
      `conceptId`* = concept s
        s.`fieldIdent` is `grantIdent`

# --- {.needs: A, B.} pragma — required-cap declarations ------------------

var grantInjectionDone* {.compileTime.}: HashSet[string]
  ## CT marker: proc names whose `currentSup`/type emission has fired.
  ## Lets `{.needs.}` and `{.inferCaps.}` coexist on the same proc
  ## without a duplicate `currentSup` template (which would be
  ## ambiguous at call sites). Grant overloads emit unconditionally —
  ## Nim accepts redundant overloads with the same signature.

var procRequiresNames* {.compileTime.}: Table[string, seq[string]]
  ## Compile-time store: proc name → list of required cap type names
  ## (e.g., ["FsReadCap", "NetworkCap"]). Populated by `{.needs.}` and
  ## `{.inferCaps.}` at macro-expansion time; read by
  ## `supervisor:` to build the concept-conjunction discharge
  ## check. Module-scoped at declaration but storage is shared across
  ## the compilation unit, so cross-module discharge works (Nim sems
  ## in dependency order; pragmas in imported modules populate this
  ## before any downstream `supervisor:` fires).

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

proc injectGrants(procDef: NimNode, procName: string,
                  capNames: seq[string]): NimNode =
  ## Prepend per-cap `grant(T: typedesc[Cap]): Grant` template overloads
  ## plus a synthetic supervisor type and `currentSup()` accessor to a
  ## proc's body.
  ##
  ## - `grant(C)`: returns the grant token for cap `C` if `C` is in the
  ##   proc's `{.needs.}`. Calls for caps NOT declared resolve to no
  ##   matching overload → standard compile error. Compile-time
  ##   validation by overload resolution.
  ##
  ## - `currentSup()`: returns `Option[ProcSup_<sym>]` where ProcSup is a
  ##   per-proc synthetic `ref object of Supervisor` with exactly the
  ##   grant fields the proc declared. The cast is contract-correct
  ##   (supervisor discharge at the spawn site already proved the actual
  ##   supervisor object carries these grant fields with the matching
  ##   layout — both subtypes are `ref object of Supervisor` so the
  ##   inheritance preamble is identical and our fields land at the
  ##   same offsets as the supervisor's actual gensym'd grant fields).
  ##
  ## Body-rewriting is a no-op for forward declarations (empty body).
  result = procDef
  if procDef.len < 7: return
  let body = procDef[6]
  if body.kind == nnkEmpty: return
  # Filter to caps registered in capMetaTable (skip unknowns silently;
  # `supervisor:` will surface them at discharge).
  var validCaps: seq[string]
  for cn in capNames:
    if cn in capMetaTable: validCaps.add cn
  if validCaps.len == 0: return
  var prepended = newStmtList()
  # Per-cap grant template overloads. Duplicate overloads (e.g. when
  # both {.needs.} and {.inferCaps.} mention the same cap) are
  # harmless in Nim — identical signatures merge.
  for capName in validCaps:
    let meta = capMetaTable[capName]
    let capIdent   = ident(capName)
    let grantIdent = ident(meta.grantType)
    prepended.add quote do:
      template grant(T: typedesc[`capIdent`]): `grantIdent` = `grantIdent`()
  # The synthetic ProcSup type and `currentSup` template must be
  # emitted at most once per proc, otherwise calls become ambiguous
  # between two distinct return types. Track via `grantInjectionDone`.
  if procName notin grantInjectionDone:
    grantInjectionDone.incl procName
    let procSupSym = genSym(nskType, "ProcSup")
    var fields = newNimNode(nnkRecList)
    for capName in validCaps:
      let meta = capMetaTable[capName]
      fields.add nnkIdentDefs.newTree(
        ident(meta.grantField),
        ident(meta.grantType),
        newEmptyNode())
    let typeDef = nnkTypeSection.newTree(
      nnkTypeDef.newTree(
        procSupSym,
        newEmptyNode(),
        nnkRefTy.newTree(
          nnkObjectTy.newTree(
            newEmptyNode(),
            nnkOfInherit.newTree(ident("Supervisor")),
            fields))))
    let supLocal = genSym(nskLet, "supRef")
    let currentSupTemplate = quote do:
      template currentSup(): Option[`procSupSym`] =
        let `supLocal` = currentSupervisor
        if `supLocal` == nil: none(`procSupSym`)
        else: some(cast[`procSupSym`](`supLocal`))
    # Only emit if Supervisor is in scope. Users importing only the
    # cap surface (capabilities.nim) get grant overloads without the
    # supervisor accessor; users importing task/supervisor get both.
    prepended.add quote do:
      when declared(Supervisor):
        `typeDef`
        `currentSupTemplate`
  let newBody = newStmtList()
  for s in prepended: newBody.add s
  if body.kind == nnkStmtList:
    for s in body: newBody.add s
  else:
    newBody.add body
  result[6] = newBody

proc capNodesOf(caps: NimNode): seq[NimNode] =
  ## Flatten a pragma/DSL argument that may be a single ident, a
  ## tuple/par construct holding several idents, or a bracket
  ## literal. Used by both `needs` and `provides(...)` parsing.
  if caps.kind in {nnkTupleConstr, nnkPar, nnkBracket}:
    for c in caps: result.add c
  else:
    result.add caps

# --- Capability AST inference --------------------------------------------

const inferenceTable = {
  # Stdlib I/O — filesystem reads
  "readFile":      "FsReadCap",
  "readLines":     "FsReadCap",
  "lines":         "FsReadCap",
  "open":          "FsReadCap",        # conservative: open in any mode implies fs touch
  "fileExists":    "FsReadCap",
  "dirExists":     "FsReadCap",
  # Stdlib I/O — filesystem writes
  "writeFile":     "FsWriteCap",
  "writeLines":    "FsWriteCap",
  "removeFile":    "FsWriteCap",
  "removeDir":     "FsWriteCap",
  "createDir":     "FsWriteCap",
  "moveFile":      "FsWriteCap",
  "copyFile":      "FsWriteCap",
  # OS processes
  "startProcess":  "ProcessCap",
  "execProcess":   "ProcessCap",
  "execShellCmd":  "ProcessCap",
  "execCmdEx":     "ProcessCap",
  # Chronos network transports — most-common entry points
  "connect":       "NetworkCap",
  "dial":          "NetworkCap",
  "bindAddress":   "NetworkCap",
  "createStreamServer":  "NetworkCap",
  "createDatagramServer": "NetworkCap",
  # fresco internal — state mutation that bypasses tracking
  "setUntracked":  "StateMutCap",
}.toTable

proc rightmostIdent(n: NimNode): string =
  ## For a callee node, return the rightmost identifier — the actual
  ## method/proc name being called. Handles `foo`, `mod.foo`,
  ## `obj.foo`, `mod.sub.foo`. Returns empty string for unusual
  ## shapes the inference table won't match anyway.
  case n.kind
  of nnkIdent, nnkSym, nnkOpenSymChoice, nnkClosedSymChoice:
    n.repr
  of nnkDotExpr:
    if n.len >= 2: rightmostIdent(n[1]) else: ""
  of nnkBracketExpr:
    # Generic instantiation like `foo[T]` — recurse into the symbol.
    if n.len >= 1: rightmostIdent(n[0]) else: ""
  else:
    ""

proc collectInferredCaps(body: NimNode, found: var HashSet[string]) =
  ## Walk `body` recursively. For each call/command node, check the
  ## callee's rightmost identifier against the inference table; add
  ## the matched cap's type name to `found`. The walk is structural
  ## (untyped AST) and uses `repr` matching — aliased/wrapped
  ## primitives are NOT detected and the user must fall back to
  ## manual `{.needs.}`.
  if body == nil: return
  case body.kind
  of nnkCall, nnkCommand, nnkInfix, nnkPrefix:
    if body.len >= 1:
      let name = rightmostIdent(body[0])
      if name.len > 0 and name in inferenceTable:
        found.incl inferenceTable[name]
    # Recurse into the call's arguments.
    for i in 1 ..< body.len: collectInferredCaps(body[i], found)
  else:
    for child in body: collectInferredCaps(child, found)

macro inferCaps*(procDef: untyped): untyped =
  ## **Macro pragma** that infers capability requirements by AST-walking
  ## the proc body. Detects calls to known primitives (readFile →
  ## FsReadCap, startProcess → ProcessCap, etc.) and unions the
  ## matching cap type names into `procRequiresNames[procName]` —
  ## the same store the manual `{.needs: ...}` pragma writes to.
  ## Manual and inferred annotations compose: the final required set
  ## is their union.
  ##
  ## **Heuristic by design.** Matching is on the callee's rightmost
  ## identifier (`repr`), so aliased / wrapped primitives are not
  ## detected. For those cases, declare the cap manually with
  ## `{.needs: ...}`. The mapping table is hardcoded for v1 (open
  ## extension as real consumers surface needs).
  ##
  ## **Pragma ordering**: place `{.inferCaps.}` BEFORE `{.async.}`
  ## in the pragma list so this macro sees the user's body, not
  ## the chronos-transformed state machine.
  let n = nameOfProc(procDef)
  if n.len == 0: return procDef
  # Locate the body. ProcDef layout: name, term-rewriting tmpl, generic
  # params, formal params, pragmas, reserved, body. Body is at index 6.
  let body = if procDef.len >= 7: procDef[6] else: newEmptyNode()
  var inferred: HashSet[string]
  collectInferredCaps(body, inferred)
  if inferred.len == 0:
    return procDef
  # Union the inferred cap names with any existing `{.needs.}` entry —
  # pragma order between `{.needs.}` and `{.inferCaps.}` doesn't matter
  # because both write to procRequiresNames at macro-expansion time and
  # the union is order-insensitive.
  if n notin procRequiresNames:
    procRequiresNames[n] = @[]
  for cn in inferred:
    if cn notin procRequiresNames[n]:
      procRequiresNames[n].add cn
  # Inject grant overloads + currentSup for the union of manual +
  # inferred caps. (Manual {.needs.} runs first per convention; its
  # injection already happened, but Nim allows multiple template
  # overload definitions and they merge naturally.)
  result = injectGrants(procDef, n, procRequiresNames[n])

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
  let capNodes = capNodesOf(caps)
  let n = nameOfProc(procDef)
  if n.len == 0: return procDef
  # μb: stash cap type names at macro-expansion time. Concept discharge
  # in `supervisor:` reads procRequiresNames directly — no
  # capKindFor / bitmap detour.
  var capNames: seq[string]
  for c in capNodes:
    if c.kind in {nnkIdent, nnkSym}:
      capNames.add c.strVal
  if n notin procRequiresNames:
    procRequiresNames[n] = @[]
  for cn in capNames:
    if cn notin procRequiresNames[n]:
      procRequiresNames[n].add cn
  result = injectGrants(procDef, n, capNames)

# --- `supervisor:` DSL ---------------------------------------------

proc collectAllProvidedCapNames*(body: NimNode, names: var HashSet[string]) =
  ## Walk a supervisor body recursively (including nested `supervisor:`
  ## blocks). For every `provides(A, B, ...)` call, add each cap
  ## identifier's source name to `names`. Used by the macro to build
  ## the unioned grant-field list for the emitted ref-object type.
  for stmt in body:
    if stmt.kind == nnkCall and stmt[0].kind == nnkIdent and
       stmt[0].strVal == "provides" and stmt.len >= 2:
      for i in 1 ..< stmt.len:
        let c = stmt[i]
        if c.kind in {nnkIdent, nnkSym}:
          names.incl c.strVal
    elif stmt.kind == nnkCall and stmt[0].kind == nnkIdent and
         stmt[0].strVal == "supervisor" and stmt.len >= 2 and
         stmt[1].kind == nnkStmtList:
      collectAllProvidedCapNames(stmt[1], names)

proc collectChildren*(body: NimNode, acc: var seq[NimNode]) =
  ## Walk a supervisor body (recursing into nested `supervisor:` blocks)
  ## and collect every `child <factoryIdent>` node. Used by the
  ## concept-based discharge to emit one `when` check per child.
  for stmt in body:
    if stmt.kind in {nnkCommand, nnkCall} and
       stmt[0].kind == nnkIdent and stmt[0].strVal == "child" and
       stmt.len >= 2:
      acc.add stmt[1]
    elif stmt.kind == nnkCall and stmt[0].kind == nnkIdent and
         stmt[0].strVal == "supervisor" and stmt.len >= 2 and
         stmt[1].kind == nnkStmtList:
      collectChildren(stmt[1], acc)

proc conceptConjunctionFor*(capNames: seq[string], typeSym: NimNode): NimNode =
  ## Build `(typeSym is GrantsA) and (typeSym is GrantsB) and ...`
  ## as AST. Empty set returns `true`.
  if capNames.len == 0:
    return newLit(true)
  result = nil
  for cn in capNames:
    if cn notin capMetaTable:
      error("discharge: capability type `" & cn & "` has no " &
            "registered metadata — declare it with `cap T` first")
    let conceptIdent = ident(capMetaTable[cn].conceptName)
    let term = nnkInfix.newTree(ident("is"), typeSym, conceptIdent)
    if result == nil: result = term
    else: result = nnkInfix.newTree(ident("and"), result, term)

macro assertCap*(caps: varargs[untyped]): untyped =
  ## Runtime assertion that every capability in `caps` is provided by
  ## some ancestor scope. Each cap expands to a `discard use(Cap)`
  ## which raises `MissingProviderError` if missing.
  ##
  ## `assertCap` is the runtime-checked fallback. The compile-time
  ## form is `{.needs: ...}` + `supervisor:`, which discharges
  ## along a statically-known supervisor topology and fails with a
  ## compile error rather than a runtime exception. Use the pragma
  ## form whenever the supervisor is statically declared; use
  ## `assertCap` inside dynamically-spawned code or to double-check
  ## at task entry.
  ##
  ## Renamed from `requires` to free that name for the compile-time
  ## pragma. The runtime semantics are unchanged.
  result = newStmtList()
  for cap in caps:
    result.add quote do:
      discard use(`cap`)
