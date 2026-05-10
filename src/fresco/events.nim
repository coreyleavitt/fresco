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
    kCtrl
    kAlt

  KeyEvent* = object
    case kind*: KeyKind
    of kChar:       rune*: Rune
    of kCtrl, kAlt: ch*:   char
    else: discard

proc simple*(k: KeyKind): KeyEvent = KeyEvent(kind: k)
proc ctrlKey*(c: char): KeyEvent  = KeyEvent(kind: kCtrl, ch: c)
proc altKey*(c: char): KeyEvent   = KeyEvent(kind: kAlt, ch: c)
proc charKey*(r: Rune): KeyEvent  = KeyEvent(kind: kChar, rune: r)

proc `==`*(a, b: KeyEvent): bool =
  if a.kind != b.kind: return false
  case a.kind
  of kChar:       a.rune == b.rune
  of kCtrl, kAlt: a.ch == b.ch
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
  of 1, 7: simple(kHome)
  of 2:    simple(kInsert)
  of 3:    simple(kDelete)
  of 4, 8: simple(kEnd)
  of 5:    simple(kPageUp)
  of 6:    simple(kPageDown)
  of 11:   simple(kF1)
  of 12:   simple(kF2)
  of 13:   simple(kF3)
  of 14:   simple(kF4)
  of 15:   simple(kF5)
  of 17:   simple(kF6)
  of 18:   simple(kF7)
  of 19:   simple(kF8)
  of 20:   simple(kF9)
  of 21:   simple(kF10)
  of 23:   simple(kF11)
  of 24:   simple(kF12)
  else:    simple(kEscape)

proc parseCsi(params: string, final: char): KeyEvent =
  case final
  of 'A': simple(kArrowUp)
  of 'B': simple(kArrowDown)
  of 'C': simple(kArrowRight)
  of 'D': simple(kArrowLeft)
  of 'H': simple(kHome)
  of 'F': simple(kEnd)
  of '~': tildeKey(parseLeadingInt(params))
  else:   simple(kEscape)

proc parseSs3(c: char): KeyEvent =
  case c
  of 'P': simple(kF1)
  of 'Q': simple(kF2)
  of 'R': simple(kF3)
  of 'S': simple(kF4)
  of 'H': simple(kHome)
  of 'F': simple(kEnd)
  else:   simple(kEscape)

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
          result.events.add simple(kEscape)
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
            result.events.add simple(kEscape); inc i; continue
          else: break
        result.events.add parseCsi(buf[i + 2 ..< j], buf[j])
        i = j + 1
      elif nxt == 'O':
        # SS3: ESC O <c>
        if i + 2 >= buf.len:
          if finalize:
            result.events.add simple(kEscape); inc i; continue
          else: break
        result.events.add parseSs3(buf[i + 2])
        i += 3
      elif nxt == '\x1B':
        # ESC ESC ... — emit a standalone Escape, re-process the rest.
        result.events.add simple(kEscape)
        inc i
      elif nxt.ord in 0x20..0x7E:
        # ESC + printable = Alt+<char>.
        result.events.add altKey(nxt)
        i += 2
      else:
        # ESC + control byte (or unknown 8-bit): treat ESC as bare and
        # let the next iteration handle the trailing byte on its own.
        result.events.add simple(kEscape)
        inc i
    of 0x0D, 0x0A:
      result.events.add simple(kEnter); inc i
    of 0x09:
      result.events.add simple(kTab); inc i
    of 0x08, 0x7F:
      result.events.add simple(kBackspace); inc i
    of 0x00:
      result.events.add ctrlKey('@'); inc i
    of 0x01..0x07, 0x0B, 0x0C, 0x0E..0x1A:
      # Ctrl+letter (lowercase canonical).
      let letter = char(b.ord - 1 + ord('a'))
      result.events.add ctrlKey(letter); inc i
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
