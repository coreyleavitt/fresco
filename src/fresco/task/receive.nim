## Selective `receive` — pattern-matched input dispatch.
##
##   receive stream:
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
##
##   receive stream:
##     Char(c):              handleChar(c)
##     after 1.seconds:      idle()
##
## The macro emits explicit CLS save/restore around its internal
## `await` (the `nextKey` / `race` calls). The enclosing proc still
## needs `{.async.}` for *its other* awaits, but `receive` itself
## doesn't depend on the enclosing pragma to preserve context across
## the suspend it introduces.

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

template isIdentLike(n: NimNode): bool =
  ## Accept any node that behaves like an identifier in untyped-macro
  ## context: bare `nnkIdent`, hygiene-wrapped `nnkSym`, or
  ## `nnkOpenSymChoice` (the compiler's pre-resolution form). Reject
  ## `nnkDotExpr`, `nnkBracketExpr`, etc. — those aren't valid DSL
  ## keyword forms.
  n.kind in {nnkIdent, nnkSym, nnkOpenSymChoice}

proc isKnownAtom(name: string): bool {.inline.} =
  ## True if `name` is in the atomMap (Tab, Enter, ArrowUp, F1, ...).
  ## Used by the arm compiler to disambiguate `Ctrl(Tab)` (modifier
  ## prefix) from `Ctrl(c)` (legacy bind-the-char form).
  name in atomMap

proc modifierFor(name: string): string =
  ## Map a modifier-prefix identifier to its `Modifier` enum string.
  ## "Shift" → "modShift" etc. Returns "" if not a modifier name.
  case name
  of "Shift": "modShift"
  of "Meta":  "modMeta"
  of "Ctrl":  "modCtrl"
  of "Alt":   "modAlt"
  else: ""

proc compilePattern(evSym, pat: NimNode): tuple[cond, prelude: NimNode]

proc compileArm(evSym, arm: NimNode): tuple[cond, body: NimNode] =
  ## Translate one arm of a receive into an (if-condition, body)
  ## pair. Wildcard arms return `cond = nil`. Modifier prefixes
  ## (`Shift(Tab)`, `Ctrl(ArrowUp)`, etc.) are handled by recursing
  ## through `compilePattern`.
  let armBody = arm[^1]

  # Wildcard: `_: body`
  if arm.kind == nnkCall and arm.len == 2 and arm[0].eqIdent("_"):
    return (nil, armBody)

  # Compile the pattern (everything except the body) and wrap.
  let pat = if arm.len == 2: arm[0]
            else: nnkCall.newTree(arm[0..^2])    # rebuild without body
  let (cond, prelude) = compilePattern(evSym, pat)
  if prelude == nil:
    return (cond, armBody)
  return (cond, newStmtList(prelude, armBody))

proc compilePattern(evSym, pat: NimNode): tuple[cond, prelude: NimNode] =
  ## Compile a pattern (no body) into a condition + optional
  ## prelude (capture bindings). The condition tests evSym against
  ## the pattern; the prelude declares any binder lets to be
  ## emitted before the arm body.
  # Atom: `Enter`, `ArrowUp`, `F1`, …
  if pat.kind in {nnkIdent, nnkSym} and isIdentLike(pat):
    let name = $pat
    let kindName = atomKindFor(name)
    if kindName.len == 0:
      error("receive: unknown atom pattern '" & name & "'", pat)
    let kindIdent = ident(kindName)
    let cond = quote do:
      `evSym`.kind == `kindIdent` and `evSym`.modifiers == {}
    return (cond, nil)

  # Call shape: Char(...), Ctrl(...), Alt(...), Shift(...), Meta(...)
  if pat.kind == nnkCall and pat.len == 2 and pat[0].isIdentLike:
    let ctor = $pat[0]
    let arg = pat[1]
    let modName = modifierFor(ctor)

    # Modifier-prefix shape: when arg is a known atom name, a
    # nested constructor call, or the modifier is Shift/Meta (which
    # never have a legacy form), treat as modifier prefix. Otherwise
    # fall through to the legacy Ctrl('c') / Alt('c') / Char(c) handling.
    let isPrefix =
      modName.len > 0 and (
        (arg.kind == nnkCall) or
        (arg.kind in {nnkIdent, nnkSym} and isKnownAtom($arg)) or
        ctor in ["Shift", "Meta"]
      )
    if isPrefix:
      # Recurse on the inner pattern, then layer this modifier on.
      let (innerCond, innerPre) = compilePattern(evSym, arg)
      let modIdent = ident(modName)
      # innerCond's modifier check is `modifiers == {}` for the
      # unmodified base. We need to REPLACE that with `modIdent in
      # modifiers` AND the rest of the cond stays. Easiest: build
      # a fresh cond that checks kind + modifier-set inclusion.
      # Re-extract just the kind check by re-running on the bare arg.
      let baseKind = if arg.kind in {nnkIdent, nnkSym}: atomKindFor($arg) else: ""
      if baseKind.len > 0:
        let baseIdent = ident(baseKind)
        # Strict-equality on the modifier set: `Shift(Tab)` matches
        # ONLY Shift+Tab, not Ctrl+Shift+Tab. Composed modifiers
        # require `Ctrl(Shift(Tab))`.
        let setLit = nnkCurly.newTree(modIdent)
        let cond = quote do:
          `evSym`.kind == `baseIdent` and `evSym`.modifiers == `setLit`
        return (cond, nil)
      elif arg.kind == nnkCall:
        # Nested: e.g. Ctrl(Shift(End)). Re-walk: gather all modifier
        # idents up the chain, find the innermost atom.
        var mods: seq[NimNode] = @[modIdent]
        var cur = arg
        while cur.kind == nnkCall and cur.len == 2 and cur[0].isIdentLike:
          let m = modifierFor($cur[0])
          if m.len > 0:
            mods.add ident(m)
            cur = cur[1]
          else: break
        # `cur` should now be the innermost atom or Char(...) constructor.
        let setLit = nnkCurly.newTree(mods)
        if cur.kind in {nnkIdent, nnkSym}:
          let bk = atomKindFor($cur)
          if bk.len == 0:
            error("receive: modifier prefix wraps unknown atom '" & $cur & "'", cur)
          let baseIdent = ident(bk)
          let cond = quote do:
            `evSym`.kind == `baseIdent` and `evSym`.modifiers == `setLit`
          return (cond, nil)
        # Nested Char(c) under modifiers: e.g. Shift(Char(c)).
        if cur.kind == nnkCall and cur.len == 2 and cur[0].eqIdent("Char"):
          let charArg = cur[1]
          if charArg.kind == nnkCharLit:
            let chLit = newLit(char(charArg.intVal))
            let cond = quote do:
              `evSym`.kind == kChar and `evSym`.rune == Rune(`chLit`) and
                `evSym`.modifiers == `setLit`
            return (cond, nil)
          elif charArg.isIdentLike:
            let binder = charArg
            let cond = quote do:
              `evSym`.kind == kChar and `evSym`.modifiers == `setLit`
            let prelude = quote do:
              let `binder` = `evSym`.rune
            return (cond, prelude)
        error("receive: unsupported modifier-prefix inner shape", arg)
      else:
        error("receive: modifier prefix expects an atom or nested Char", arg)

    # Legacy / non-prefix constructors
    case ctor
    of "Char":
      if arg.kind == nnkCharLit:
        let chLit = newLit(char(arg.intVal))
        let cond = quote do:
          `evSym`.kind == kChar and `evSym`.rune == Rune(`chLit`) and
            `evSym`.modifiers == {}
        return (cond, nil)
      elif arg.isIdentLike:
        let binder = arg
        let cond = quote do:
          `evSym`.kind == kChar and `evSym`.modifiers == {}
        let prelude = quote do:
          let `binder` = `evSym`.rune
        return (cond, prelude)
      else:
        error("Char pattern: expected char literal or identifier", arg)
    of "Ctrl":
      if arg.kind == nnkCharLit:
        let chLit = newLit(char(arg.intVal))
        let cond = quote do:
          `evSym`.kind == kChar and `evSym`.rune == Rune(`chLit`) and
            `evSym`.modifiers == {modCtrl}
        return (cond, nil)
      elif arg.isIdentLike:
        let binder = arg
        let cond = quote do:
          `evSym`.kind == kChar and `evSym`.modifiers == {modCtrl}
        let prelude = quote do:
          let `binder` = `evSym`.rune
        return (cond, prelude)
      else:
        error("Ctrl pattern: expected char literal or identifier", arg)
    of "Alt":
      if arg.kind == nnkCharLit:
        let chLit = newLit(char(arg.intVal))
        let cond = quote do:
          `evSym`.kind == kChar and `evSym`.rune == Rune(`chLit`) and
            `evSym`.modifiers == {modAlt}
        return (cond, nil)
      elif arg.isIdentLike:
        let binder = arg
        let cond = quote do:
          `evSym`.kind == kChar and `evSym`.modifiers == {modAlt}
        let prelude = quote do:
          let `binder` = `evSym`.rune
        return (cond, prelude)
      else:
        error("Alt pattern: expected char literal or identifier", arg)
    else:
      error("receive: unknown constructor pattern '" & ctor & "'", pat[0])

  error("receive: unrecognized pattern shape\n" & pat.treeRepr, pat)

proc isAfterArm(arm: NimNode): bool =
  ## Detect `after <Duration>: body`. AST: Command(after, durExpr, StmtList(body))
  ## or Call(after, durExpr, StmtList(body)). eqIdent so hygiene
  ## wrapping in a containing template doesn't miss the match.
  if arm.kind notin {nnkCall, nnkCommand}: return false
  if arm.len < 2: return false
  arm[0].eqIdent("after")

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
  if arm.len == 2 and arm[0].isIdentLike:
    if arm[0].eqIdent("_"): return "*"
    let k = atomKindFor($arm[0])
    if k.len > 0: return k
    return ""
  if arm.len == 3 and arm[0].isIdentLike:
    let ctor = $arm[0]
    let arg = arm[1]
    # Only a capture (identifier) is fully-covering; a literal or
    # modifier-prefix pins specific values. Under the modifier-set
    # model both Ctrl(c) and Alt(c) bind to a kChar with a specific
    # modifier — coverage attribution is to kChar.
    if arg.isIdentLike and not isKnownAtom($arg):
      case ctor
      of "Char": return "kChar"
      of "Ctrl", "Alt": return "kChar"
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
    # fires first. The outer try/finally guarantees both futures are
    # cancelled on every exit path — including a `CancelledError`
    # propagating out of the race itself, which would otherwise
    # orphan the `nextKey` future and silently consume the next
    # keypress with no consumer.
    #
    # `.read` on a finished `keyFut` re-raises if it failed (e.g.
    # `InputStreamClosedError` on stream close), so stream-close
    # propagates rather than being mistaken for a timeout.
    let keyFutSym = genSym(nskLet, "keyFut")
    let timerSym  = genSym(nskLet, "timerFut")
    result = quote do:
      let `keyFutSym` = `stream`.nextKey()
      let `timerSym`  = sleepAsync(`afterDur`)
      try:
        discard await race(FutureBase(`keyFutSym`), FutureBase(`timerSym`))
        if `keyFutSym`.finished:
          let `evSym` = `keyFutSym`.read   # re-raises on failure
          `chain`
        else:
          `afterBody`
      finally:
        if not `keyFutSym`.finished: `keyFutSym`.cancelSoon()
        if not `timerSym`.finished:  `timerSym`.cancelSoon()

# --- Multi-source receive (#66) -----------------------------------------

proc parseOnArm(stmt: NimNode): tuple[source, varName, body: NimNode] =
  ## Parse an `on <source> as <var>: <body>` command. The shape is:
  ##   Command(Ident "on",
  ##           Infix(Ident "as", <source>, <var>),
  ##           StmtList <body>)
  ## Returns (nil, nil, nil) on shape mismatch — caller flags the error.
  if stmt.kind != nnkCommand or stmt.len != 3: return
  if stmt[0].kind != nnkIdent or stmt[0].strVal != "on": return
  let infix = stmt[1]
  if infix.kind != nnkInfix or infix.len != 3: return
  if infix[0].kind != nnkIdent or infix[0].strVal != "as": return
  if stmt[2].kind != nnkStmtList: return
  (source: infix[1], varName: infix[2], body: stmt[2])

proc parseAfterArm(stmt: NimNode): tuple[dur, body: NimNode] =
  ## Parse an `after <Duration>: <body>` command in the multi-source
  ## form. Same shape as the single-source receive's after arm.
  if stmt.kind != nnkCommand or stmt.len != 3: return
  if stmt[0].kind != nnkIdent or stmt[0].strVal != "after": return
  if stmt[2].kind != nnkStmtList: return
  (dur: stmt[1], body: stmt[2])

macro receive*(body: untyped): untyped =
  ## Multi-source selective receive (#66). Races multiple typed event
  ## sources and dispatches the body of the source that produced the
  ## next event. Each `on <source> as <var>:` block declares one
  ## source; the var binds to its produced event.
  ##
  ##   receive:
  ##     on stream as ev:
  ##       case ev.kind
  ##       of kChar: ...
  ##     on askQueue as ask:
  ##       handle(ask)
  ##     after 1.seconds:
  ##       rerenderIdle()
  ##
  ## Each source must satisfy the EventSource protocol — duck-typed
  ## as `proc nextEvent(s: T): Future[E]` overload in scope.
  ## `InputStream` and `Mailbox[T]` ship with the conformance; user
  ## types can satisfy it by adding the overload.
  ##
  ## Cancel safety: every losing source's future is cancelled in the
  ## `finally` block. Events queued in the source's internal buffer
  ## survive — they're returned by the next `nextEvent` call.
  expectKind(body, nnkStmtList)

  var onArms: seq[tuple[source, varName, body: NimNode]] = @[]
  var afterDur, afterBody: NimNode = nil
  for stmt in body:
    let onArm = parseOnArm(stmt)
    if onArm.source != nil:
      onArms.add onArm
      continue
    let aft = parseAfterArm(stmt)
    if aft.dur != nil:
      if afterDur != nil:
        error("receive: at most one `after` clause", stmt)
      afterDur = aft.dur
      afterBody = aft.body
      continue
    error("receive: each statement in the body must be `on <source> as " &
          "<var>: <body>` or `after <Duration>: <body>`", stmt)

  if onArms.len == 0 and afterDur == nil:
    error("receive: body must contain at least one `on` block or an " &
          "`after` clause", body)

  # Emit:
  #   block:
  #     let fut0 = source0.nextEvent()
  #     let fut1 = source1.nextEvent()
  #     [let timer = sleepAsync(<dur>)]
  #     try:
  #       discard await race(FutureBase(fut0), ..., FutureBase(timer))
  #       if fut0.finished: let var0 = fut0.read; body0
  #       elif fut1.finished: let var1 = fut1.read; body1
  #       [else: afterBody]
  #     finally:
  #       if not fut0.finished: fut0.cancelSoon()
  #       ...
  var futSyms: seq[NimNode] = @[]
  for _ in onArms: futSyms.add genSym(nskLet, "ev_fut")
  let timerSym = genSym(nskLet, "timer_fut")

  # let-bindings for source futures (and optional timer)
  let setup = newStmtList()
  for i, arm in onArms:
    let f = futSyms[i]
    let src = arm.source
    setup.add quote do:
      let `f` = `src`.nextEvent()
  if afterDur != nil:
    let d = afterDur
    setup.add quote do:
      let `timerSym` = sleepAsync(`d`)

  # race(...) call
  let raceCall = newCall(ident"race")
  for f in futSyms:
    raceCall.add newCall(ident"FutureBase", f)
  if afterDur != nil:
    raceCall.add newCall(ident"FutureBase", timerSym)

  # Track which source's body ran ("won"). Used by the cleanup
  # block to skip restoreEvent on the winner (its value was
  # consumed; restoring would re-deliver). -1 = nothing dispatched
  # (after-arm fired or all sources are pending).
  let wonSym = genSym(nskVar, "receive_won")

  # dispatch chain
  let dispatch = newNimNode(nnkIfStmt)
  for i, arm in onArms:
    let f = futSyms[i]
    let v = arm.varName
    let b = arm.body
    let idxLit = newLit(i)
    dispatch.add newTree(nnkElifBranch,
      newDotExpr(f, ident"finished"),
      quote do:
        `wonSym` = `idxLit`
        let `v` = `f`.read
        `b`)
  if afterDur != nil:
    dispatch.add newTree(nnkElse, afterBody)

  # finally: cancel pending losers; restore finished-but-not-dispatched
  # losers' values back to their source via restoreEvent. This is the
  # cancel-race safety the issue called out — when multiple sources
  # have events ready simultaneously, all nextEvent futures finish
  # synchronously but only one body runs; the others' values would
  # silently drop without restoreEvent.
  let cleanup = newStmtList()
  for i, arm in onArms:
    let f = futSyms[i]
    let src = arm.source
    let idxLit = newLit(i)
    cleanup.add quote do:
      if `wonSym` != `idxLit`:
        if not `f`.finished:
          `f`.cancelSoon()
        elif not `f`.failed:
          `src`.restoreEvent(`f`.read)
  if afterDur != nil:
    cleanup.add quote do:
      if not `timerSym`.finished: `timerSym`.cancelSoon()

  let raceStmt = nnkDiscardStmt.newTree(newCall(ident"await", raceCall))
  let initWon = quote do:
    var `wonSym` = -1
  let tryBody = newStmtList(raceStmt, dispatch)
  let tryStmt = newTree(nnkTryStmt, tryBody,
    newTree(nnkFinally, cleanup))

  result = newBlockStmt(newStmtList(setup, initWon, tryStmt))
