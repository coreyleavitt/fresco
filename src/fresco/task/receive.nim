## Selective `receive` — pattern-matched input dispatch.
##
##   case (await receive(stream)):
##     Char('+'):   count.set(count() + 1)
##     Char('-'):   count.set(count() - 1)
##     Ctrl('c'):   return
##     Char(c):     handleChar(c)         # capture remaining chars
##     Enter:       submit()
##     ArrowUp:     moveUp()
##     F1:          showHelp()
##     _:           discard
##
## Pattern arms are matched in source order — put specific patterns
## before catch-alls. The macro compiles to an `if/elif` chain over the
## `KeyEvent` shape produced by `stream.nextKey()`. Capture identifiers
## (`Char(c)`, `Ctrl(c)`, `Alt(c)`) bind a local `let` in the arm body.
##
## Arms can also include `after Duration: body` to time out the receive.

import std/[macros, sets, tables, unicode]
import chronos
import ../events
import ../input

const atomMap = {
  "Enter":      "kEnter",
  "Tab":        "kTab",
  "Backspace":  "kBackspace",
  "Escape":     "kEscape",
  "Delete":     "kDelete",
  "Insert":     "kInsert",
  "Home":       "kHome",
  "End":        "kEnd",
  "PageUp":     "kPageUp",
  "PageDown":   "kPageDown",
  "ArrowUp":    "kArrowUp",
  "ArrowDown":  "kArrowDown",
  "ArrowLeft":  "kArrowLeft",
  "ArrowRight": "kArrowRight",
  "F1":  "kF1",  "F2":  "kF2",  "F3":  "kF3",  "F4":  "kF4",
  "F5":  "kF5",  "F6":  "kF6",  "F7":  "kF7",  "F8":  "kF8",
  "F9":  "kF9",  "F10": "kF10", "F11": "kF11", "F12": "kF12",
}.toTable

proc atomKindFor(name: string): string =
  if name in atomMap: atomMap[name] else: ""

proc compileArm(evSym, arm: NimNode): tuple[cond, body: NimNode] =
  ## Translate one arm of a receive into an (if-condition, body) pair
  ## suitable for inclusion in an elif chain. Wildcard arms return
  ## `cond = nil` — the caller emits them as `nnkElse` for a cleaner
  ## AST than `elif true:`.
  let armBody = arm[^1]

  # Wildcard: `_: body`
  if arm.kind == nnkCall and arm.len == 2 and
     arm[0].kind == nnkIdent and $arm[0] == "_":
    return (nil, armBody)

  # Atom: `Enter: body`, `ArrowUp: body`, `F1: body` …
  if arm.kind == nnkCall and arm.len == 2 and arm[0].kind == nnkIdent:
    let name = $arm[0]
    let kindName = atomKindFor(name)
    if kindName.len == 0:
      error("receive: unknown atom pattern '" & name & "'", arm[0])
    let kindIdent = ident(kindName)
    let cond = quote do: `evSym`.kind == `kindIdent`
    return (cond, armBody)

  # Constructor: `Char('+')` / `Char(c)` / `Ctrl('c')` / `Alt(a)`
  if arm.kind == nnkCall and arm.len == 3 and arm[0].kind == nnkIdent:
    let ctor = $arm[0]
    let argument = arm[1]

    case ctor
    of "Char":
      if argument.kind == nnkCharLit:
        let chLit = newLit(char(argument.intVal))
        let cond = quote do:
          `evSym`.kind == kChar and `evSym`.rune == Rune(`chLit`)
        return (cond, armBody)
      elif argument.kind == nnkIdent:
        let binder = argument
        let cond = quote do: `evSym`.kind == kChar
        let wrapped = quote do:
          let `binder` = `evSym`.rune
          `armBody`
        return (cond, wrapped)
      else:
        error("Char pattern: expected char literal or identifier", argument)
    of "Ctrl":
      if argument.kind == nnkCharLit:
        let chLit = newLit(char(argument.intVal))
        let cond = quote do:
          `evSym`.kind == kCtrl and `evSym`.ch == `chLit`
        return (cond, armBody)
      elif argument.kind == nnkIdent:
        let binder = argument
        let cond = quote do: `evSym`.kind == kCtrl
        let wrapped = quote do:
          let `binder` = `evSym`.ch
          `armBody`
        return (cond, wrapped)
      else:
        error("Ctrl pattern: expected char literal or identifier", argument)
    of "Alt":
      if argument.kind == nnkCharLit:
        let chLit = newLit(char(argument.intVal))
        let cond = quote do:
          `evSym`.kind == kAlt and `evSym`.ch == `chLit`
        return (cond, armBody)
      elif argument.kind == nnkIdent:
        let binder = argument
        let cond = quote do: `evSym`.kind == kAlt
        let wrapped = quote do:
          let `binder` = `evSym`.ch
          `armBody`
        return (cond, wrapped)
      else:
        error("Alt pattern: expected char literal or identifier", argument)
    else:
      error("receive: unknown constructor pattern '" & ctor & "'", arm[0])

  error("receive: unrecognized arm shape\n" & arm.treeRepr, arm)

proc isAfterArm(arm: NimNode): bool =
  ## Detect `after <Duration>: body`. AST: Command(after, durExpr, StmtList(body))
  ## or Call(after, durExpr, StmtList(body)).
  if arm.kind notin {nnkCall, nnkCommand}: return false
  if arm.len < 2: return false
  let head = arm[0]
  head.kind == nnkIdent and $head == "after"

const allKeyKinds = block:
  ## Derived from the `KeyKind` enum so adding a new key in events.nim
  ## doesn't silently break exhaustiveness analysis here.
  var s: seq[string] = @[]
  for k in KeyKind: s.add $k
  s

proc kindCoveredByArm(arm: NimNode): string =
  ## If this arm "fully covers" a KeyKind (no literal constraint),
  ## return the kind name. Otherwise return "" (partial / not-covering).
  ## Wildcard arms return a sentinel "*".
  if arm.kind notin {nnkCall, nnkCommand}: return ""
  if arm.len == 2 and arm[0].kind == nnkIdent:
    let name = $arm[0]
    if name == "_": return "*"
    let k = atomKindFor(name)
    if k.len > 0: return k
    return ""
  if arm.len == 3 and arm[0].kind == nnkIdent:
    let ctor = $arm[0]
    let arg = arm[1]
    # Only a capture (identifier) is fully-covering; a literal pins
    # one specific char.
    if arg.kind == nnkIdent:
      case ctor
      of "Char": return "kChar"
      of "Ctrl": return "kCtrl"
      of "Alt":  return "kAlt"
      else: discard
  return ""

macro receive*(stream: untyped, body: untyped): untyped =
  ## Block until the next KeyEvent arrives on `stream`; dispatch to
  ## the first matching arm. Returns the value of the arm's body
  ## expression. With an `after Duration:` arm, races the key wait
  ## against a chronos timer; if the timer fires first, runs the
  ## timeout body instead.
  expectKind(body, nnkStmtList)

  let evSym = genSym(nskLet, "ev")
  var afterDur: NimNode = nil
  var afterBody: NimNode = nil
  var covered = initHashSet[string]()
  var hasWildcard = false
  var wildcardSeenAt = -1
  var nonAfterArms: seq[NimNode] = @[]

  # First pass: separate `after` from regular arms, track coverage,
  # warn on arms that appear after a wildcard (they would be
  # unreachable since the wildcard always matches).
  var idx = 0
  for arm in body:
    if isAfterArm(arm):
      if afterDur != nil:
        error("receive: at most one `after` clause", arm)
      afterDur = arm[1]
      afterBody = arm[^1]
      continue
    let cov = kindCoveredByArm(arm)
    if cov == "*":
      hasWildcard = true
      if wildcardSeenAt < 0: wildcardSeenAt = idx
    elif cov.len > 0: covered.incl cov
    if wildcardSeenAt >= 0 and idx > wildcardSeenAt:
      warning("receive: arm appears after the wildcard `_:` and is " &
              "unreachable", arm)
    nonAfterArms.add arm
    inc idx

  if not hasWildcard:
    var missing: seq[string] = @[]
    for k in allKeyKinds:
      if k notin covered: missing.add k
    if missing.len > 0 and missing.len < allKeyKinds.len:
      hint("receive: no `_:` arm and some KeyKinds are uncovered — " &
           "matching keys will be silently dropped. " &
           "Uncovered: " & $missing)

  if nonAfterArms.len == 0 and afterDur == nil:
    error("receive: body must contain at least one key arm or an " &
          "`after Duration:` clause — otherwise the receive is a no-op",
          body)

  # Second pass: emit one elif per arm in source order. The wildcard
  # arm becomes an elif with condition `true`, which makes it match
  # all remaining events. nnkIfStmt (not nnkIfExpr) so statement-
  # shaped arm bodies (return, discard, mixed value/void) compose
  # correctly. When `nonAfterArms` is empty (after-only receive), we
  # skip the chain entirely — emitting an `nnkIfStmt` with no elif
  # branches is invalid AST.
  var chain: NimNode
  if nonAfterArms.len > 0:
    chain = newNimNode(nnkIfStmt)
    for arm in nonAfterArms:
      let (cond, armBody) = compileArm(evSym, arm)
      if cond == nil:
        # Wildcard — emit as an else branch (cleaner AST than
        # `elif true:`, and Nim doesn't warn on "always-true cond").
        chain.add newTree(nnkElse, armBody)
      else:
        chain.add newTree(nnkElifBranch, cond, armBody)
    if not hasWildcard:
      # Final else is a no-op so the if-statement remains total.
      chain.add newTree(nnkElse, quote do: discard)
  else:
    # After-only receive — the key path consumes one event and
    # discards it; the timer path runs `afterBody`.
    chain = quote do: discard

  if afterDur == nil:
    result = quote do:
      let `evSym` = await `stream`.nextKey()
      `chain`
  else:
    # Race the next-key wait against a sleepAsync; dispatch on which
    # fires first.
    let keyFutSym = genSym(nskLet, "keyFut")
    let timerSym  = genSym(nskLet, "timerFut")
    result = quote do:
      let `keyFutSym` = `stream`.nextKey()
      let `timerSym`  = sleepAsync(`afterDur`)
      discard await race(FutureBase(`keyFutSym`), FutureBase(`timerSym`))
      if `keyFutSym`.finished and not `keyFutSym`.failed:
        if not `timerSym`.finished: `timerSym`.cancelSoon()
        let `evSym` = `keyFutSym`.read
        `chain`
      else:
        if not `keyFutSym`.finished: `keyFutSym`.cancelSoon()
        `afterBody`
