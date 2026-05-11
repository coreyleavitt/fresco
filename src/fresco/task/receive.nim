## Selective `receive` — pattern-matched input dispatch.
import std/tables
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
## v2.0 scope: core patterns + wildcard. `after Duration:` timeout arms
## land in a follow-up commit together with exhaustiveness checking.

import std/[macros, unicode]
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
  ## suitable for inclusion in an elif chain.
  let armBody = arm[^1]

  # Wildcard: `_: body`
  if arm.kind == nnkCall and arm.len == 2 and
     arm[0].kind == nnkIdent and $arm[0] == "_":
    return (newLit(true), armBody)

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

macro receive*(stream: untyped, body: untyped): untyped =
  ## Block until the next KeyEvent arrives on `stream`; dispatch to
  ## the first matching arm. Returns the value of the arm's body
  ## expression, so `receive` can be used both as a statement and as
  ## an expression yielding a result.
  expectKind(body, nnkStmtList)

  let evSym = genSym(nskLet, "ev")
  var chain: NimNode = nil
  var elseBody: NimNode = nil

  for arm in body:
    let (cond, armBody) = compileArm(evSym, arm)
    if cond.kind == nnkIntLit and cond.intVal != 0:
      # Wildcard arm — keep as `else` for the chain. If multiple
      # wildcards appear, the last wins; warn at compile time later.
      elseBody = armBody
    else:
      if chain == nil:
        chain = newNimNode(nnkIfExpr)
      chain.add newTree(nnkElifBranch, cond, armBody)

  if chain == nil:
    chain = newNimNode(nnkIfExpr)
  if elseBody != nil:
    chain.add newTree(nnkElse, elseBody)
  else:
    # No wildcard. Use `discard` as the fall-through to keep the
    # expression total. Future commit upgrades this to a compile
    # warning when exhaustiveness isn't satisfied otherwise.
    chain.add newTree(nnkElse, quote do: discard)

  result = quote do:
    let `evSym` = await `stream`.nextKey()
    `chain`
