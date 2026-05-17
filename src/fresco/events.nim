## KeyEvent type + pure byte-stream decoder.
##
## `decode(buf, finalize)` consumes bytes from the front of `buf` and
## returns the events it produced plus the number of bytes it consumed.
## Anything left unconsumed is a partial escape sequence (or partial
## UTF-8 rune) the caller should carry over and prepend to its next
## read. When the caller times out waiting for more bytes, it calls
## `decode` again with `finalize = true` so a bare ESC is reported as
## kEscape instead of being held forever.

import std/unicode

type
  Modifier* = enum
    ## Modifier flags that compose with a base `KeyKind`. Encoded as
    ## an orthogonal `set[Modifier]` rather than baking each
    ## combination into the enum — the latter combinatorially
    ## explodes (~6 modifier sets × ~20 base keys).
    ##
    ## Terminal protocol mapping (xterm `CSI 1;<code><final>`):
    ## code = 1 + (shift?1:0) + (alt?2:0) + (ctrl?4:0) + (meta?8:0)
    modShift
    modAlt
    modCtrl
    modMeta

  Modifiers* = set[Modifier]

  KeyKind* = enum
    kChar
    kEnter
    kTab
    kBackspace
    kEscape
    kArrowUp
    kArrowDown
    kArrowLeft
    kArrowRight
    kHome
    kEnd
    kPageUp
    kPageDown
    kDelete
    kInsert
    kF1, kF2, kF3, kF4, kF5, kF6, kF7, kF8, kF9, kF10, kF11, kF12

  KeyEvent* = object
    ## A keyboard event: a base key (`kind`) plus any active
    ## modifiers. Shift+Tab is `(kTab, {modShift})`;
    ## Ctrl+ArrowUp is `(kArrowUp, {modCtrl})`; Ctrl+'c' is
    ## `(kChar, 'c', {modCtrl})` — what the legacy `ctrlKey('c')`
    ## constructor now produces. Bare keys carry an empty modifier
    ## set.
    case kind*: KeyKind
    of kChar: rune*: Rune
    else: discard
    modifiers*: Modifiers

proc atomKey*(k: KeyKind): KeyEvent = KeyEvent(kind: k)
  ## Constructor for an unmodified, kind-only KeyEvent.

proc ctrlKey*(c: char): KeyEvent =
  ## Construct a Ctrl+<char> event. Under the modifier-set model
  ## (#67) this is a `kChar` with `modCtrl` in the modifier set —
  ## not a separate `kCtrl` kind anymore. The constructor signature
  ## is preserved so existing call sites and arm patterns
  ## (`Ctrl('c'): ...`) continue to work unchanged.
  KeyEvent(kind: kChar, rune: Rune(c), modifiers: {modCtrl})

proc altKey*(c: char): KeyEvent =
  ## Construct an Alt+<char> event. Same model shift as `ctrlKey`.
  KeyEvent(kind: kChar, rune: Rune(c), modifiers: {modAlt})

proc charKey*(r: Rune): KeyEvent =
  KeyEvent(kind: kChar, rune: r)

proc summary*(ev: KeyEvent): string =
  ## Compact human-readable rendering. Modifiers prefix the base
  ## key in fixed order (Shift, Alt, Ctrl, Meta) so a Ctrl+Shift+End
  ## reads as `"Shift+Ctrl+End"`.
  ##
  ## Single-modifier Ctrl/Alt + char keeps the legacy hyphen form
  ## (`"Ctrl-q"`, `"Alt-c"`) for terminal-style reading. Multi-
  ## modifier or non-char keys use the `+`-prefix form.
  if ev.kind == kChar and ev.modifiers.card == 1:
    if modCtrl in ev.modifiers: return "Ctrl-" & $ev.rune
    if modAlt  in ev.modifiers: return "Alt-"  & $ev.rune
  var prefix = ""
  if modShift in ev.modifiers: prefix &= "Shift+"
  if modAlt   in ev.modifiers: prefix &= "Alt+"
  if modCtrl  in ev.modifiers: prefix &= "Ctrl+"
  if modMeta  in ev.modifiers: prefix &= "Meta+"
  case ev.kind
  of kChar: prefix & "Char(" & $ev.rune & ")"
  else:     prefix & $ev.kind

proc `==`*(a, b: KeyEvent): bool =
  if a.kind != b.kind: return false
  if a.modifiers != b.modifiers: return false
  case a.kind
  of kChar: a.rune == b.rune
  else: true

# --- UTF-8 helpers ---------------------------------------------------------

proc utf8Len(lead: char): int =
  let b = lead.uint8
  if   (b and 0x80'u8) == 0x00'u8: 1
  elif (b and 0xE0'u8) == 0xC0'u8: 2
  elif (b and 0xF0'u8) == 0xE0'u8: 3
  elif (b and 0xF8'u8) == 0xF0'u8: 4
  else: 1  # invalid lead — consume one byte to make progress

# --- CSI parameter parsing -------------------------------------------------

proc parseLeadingInt(s: string): int =
  ## Read leading decimal digits; returns 0 if none.
  var k = 0
  while k < s.len and s[k] in {'0'..'9'}:
    result = result * 10 + (s[k].ord - ord('0'))
    inc k

proc tildeKey(n: int): KeyEvent =
  case n
  of 1, 7: atomKey(kHome)
  of 2:    atomKey(kInsert)
  of 3:    atomKey(kDelete)
  of 4, 8: atomKey(kEnd)
  of 5:    atomKey(kPageUp)
  of 6:    atomKey(kPageDown)
  of 11:   atomKey(kF1)
  of 12:   atomKey(kF2)
  of 13:   atomKey(kF3)
  of 14:   atomKey(kF4)
  of 15:   atomKey(kF5)
  of 17:   atomKey(kF6)
  of 18:   atomKey(kF7)
  of 19:   atomKey(kF8)
  of 20:   atomKey(kF9)
  of 21:   atomKey(kF10)
  of 23:   atomKey(kF11)
  of 24:   atomKey(kF12)
  else:    atomKey(kEscape)

proc atomFromFinal(final: char): KeyKind =
  ## Map a CSI/SS3 final byte to its base KeyKind (modifier-agnostic).
  ## Used by both the no-modifier path (single-letter final) and the
  ## CSI 1;<mod><final> form to share the same key mapping.
  case final
  of 'A': kArrowUp
  of 'B': kArrowDown
  of 'C': kArrowRight
  of 'D': kArrowLeft
  of 'H': kHome
  of 'F': kEnd
  of 'P': kF1
  of 'Q': kF2
  of 'R': kF3
  of 'S': kF4
  of 'Z': kTab           ## CSI Z = Shift+Tab (modifier applied by caller)
  else:   kEscape

proc decodeModifierCode(code: int): Modifiers =
  ## xterm modifyOtherKeys encoding: `code = 1 + flags` where
  ## flags = shift|alt<<1|ctrl<<2|meta<<3. code 1 = no modifier;
  ## code 2 = Shift; code 5 = Ctrl; code 6 = Ctrl+Shift; etc.
  ## Codes outside the conventional 1..16 range degrade to the
  ## empty set rather than raising.
  if code < 2 or code > 16: return
  let flags = code - 1
  if (flags and 0b0001) != 0: result.incl modShift
  if (flags and 0b0010) != 0: result.incl modAlt
  if (flags and 0b0100) != 0: result.incl modCtrl
  if (flags and 0b1000) != 0: result.incl modMeta

proc parseSplit(params: string): seq[int] =
  ## Split a CSI params string on `;` and parse each segment as an
  ## int. Empty segments → 0 (per ECMA-48 default-param convention).
  var cur = 0
  var inDigits = false
  for ch in params:
    if ch in {'0'..'9'}:
      cur = cur * 10 + (ch.ord - ord('0'))
      inDigits = true
    elif ch == ';':
      result.add (if inDigits: cur else: 0)
      cur = 0; inDigits = false
    else:
      # Unexpected char — treat as separator to make progress.
      result.add (if inDigits: cur else: 0)
      cur = 0; inDigits = false
  if inDigits or params.len > 0: result.add cur

proc parseCsi(params: string, final: char): KeyEvent =
  # Legacy single-final, no modifier params: e.g. `\e[A`, `\e[Z`.
  if params.len == 0:
    case final
    of 'Z':
      # Legacy Shift+Tab encoding — no params, but Shift is implied.
      return KeyEvent(kind: kTab, modifiers: {modShift})
    of '~':
      return tildeKey(0)        # no params for tilde → 0 → kEscape
    else:
      let k = atomFromFinal(final)
      return atomKey(k)
  # `~`-finalized tilde keys carry the function-key index, not the
  # modifier form. e.g. `\e[15~` = F5. Modifier-aware tilde keys
  # (`\e[<n>;<mod>~`) are an xterm extension we accept by stripping
  # any trailing `;<mod>` and forwarding the base index.
  if final == '~':
    let parts = parseSplit(params)
    var ev = tildeKey(parts[0])
    if parts.len >= 2:
      ev.modifiers = decodeModifierCode(parts[1])
    return ev
  # xterm modifyOtherKeys form: `\e[1;<mod><final>` where the leading
  # `1` is the "key index" placeholder for non-tilde keys. We
  # recognize this shape and apply the modifier.
  let parts = parseSplit(params)
  if parts.len >= 2 and parts[0] == 1:
    let base = atomFromFinal(final)
    return KeyEvent(kind: base, modifiers: decodeModifierCode(parts[1]))
  # Unrecognized shape — fall back to legacy decoder.
  case final
  of 'Z': KeyEvent(kind: kTab, modifiers: {modShift})
  else: atomKey(atomFromFinal(final))

proc parseSs3(c: char): KeyEvent =
  case c
  of 'P': atomKey(kF1)
  of 'Q': atomKey(kF2)
  of 'R': atomKey(kF3)
  of 'S': atomKey(kF4)
  of 'H': atomKey(kHome)
  of 'F': atomKey(kEnd)
  of 'Z': KeyEvent(kind: kTab, modifiers: {modShift})  ## SS3 Shift+Tab
  else:   atomKey(kEscape)

# --- Main decoder ----------------------------------------------------------

proc decode*(buf: string, finalize: bool = false):
    tuple[events: seq[KeyEvent], consumed: int] =
  ## Pure: no I/O. Consumes complete sequences from the front of `buf`.
  ## Partial trailing sequences are left unconsumed unless `finalize`
  ## is true, in which case a bare ESC flushes as kEscape.
  var i = 0
  while i < buf.len:
    let b = buf[i]
    case b.ord
    of 0x1B:
      # ESC introducer.
      if i + 1 >= buf.len:
        if finalize:
          result.events.add atomKey(kEscape)
          inc i
        else:
          break
        continue
      let nxt = buf[i + 1]
      if nxt == '[':
        # CSI: ESC [ <params> <final 0x40..0x7E>
        var j = i + 2
        while j < buf.len and buf[j].ord notin {0x40..0x7E}: inc j
        if j >= buf.len:
          if finalize:
            result.events.add atomKey(kEscape); inc i; continue
          else: break
        result.events.add parseCsi(buf[i + 2 ..< j], buf[j])
        i = j + 1
      elif nxt == 'O':
        # SS3: ESC O <c>
        if i + 2 >= buf.len:
          if finalize:
            result.events.add atomKey(kEscape); inc i; continue
          else: break
        result.events.add parseSs3(buf[i + 2])
        i += 3
      elif nxt == '\x1B':
        # ESC ESC ... — emit a standalone Escape, re-process the rest.
        result.events.add atomKey(kEscape)
        inc i
      elif nxt.ord in 0x20..0x7E:
        # ESC + printable = Alt+<char>.
        result.events.add altKey(nxt)
        i += 2
      else:
        # ESC + control byte (or unknown 8-bit): treat ESC as bare and
        # let the next iteration handle the trailing byte on its own.
        result.events.add atomKey(kEscape)
        inc i
    of 0x0D, 0x0A:
      result.events.add atomKey(kEnter); inc i
    of 0x09:
      result.events.add atomKey(kTab); inc i
    of 0x08, 0x7F:
      result.events.add atomKey(kBackspace); inc i
    of 0x00:
      # NUL byte is canonical Ctrl-@ per the ASCII table (and what
      # most terminals deliver when the user types it). Treating it
      # as Ctrl-@ keeps the kCtrl decoder uniform — every control
      # byte 0x00..0x1A maps to a printable letter via `letter - 1`.
      result.events.add ctrlKey('@'); inc i
    of 0x01..0x07, 0x0B, 0x0C, 0x0E..0x1A:
      # Ctrl+letter (lowercase canonical).
      let letter = char(b.ord - 1 + ord('a'))
      result.events.add ctrlKey(letter); inc i
    of 0x1C..0x1F:
      # Ctrl-\ (0x1C), Ctrl-] (0x1D), Ctrl-^ (0x1E), Ctrl-_ (0x1F).
      # ASCII convention: byte + 0x40 yields the printable character
      # (0x1C → '\\', 0x1D → ']', 0x1E → '^', 0x1F → '_'). The earlier
      # 0x01..0x1A range uses lowercase letters; this range uses the
      # symbol characters per the standard control-byte mapping.
      let symbol = char(b.ord + 0x40)
      result.events.add ctrlKey(symbol); inc i
    else:
      # Printable / UTF-8.
      let need = utf8Len(b)
      if i + need > buf.len:
        # Partial UTF-8 — leave unconsumed.
        break
      let r = buf.runeAt(i)
      result.events.add charKey(r)
      i += need
  result.consumed = i
