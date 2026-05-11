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

proc atomKey*(k: KeyKind): KeyEvent = KeyEvent(kind: k)
  ## Constructor for a kind-only KeyEvent (no payload — Enter, Tab,
  ## arrows, F-keys, etc.). Matches `charKey` / `ctrlKey` / `altKey`
  ## naming so the four KeyEvent constructors form a coherent set.
proc ctrlKey*(c: char): KeyEvent  = KeyEvent(kind: kCtrl, ch: c)
proc altKey*(c: char): KeyEvent   = KeyEvent(kind: kAlt, ch: c)
proc charKey*(r: Rune): KeyEvent  = KeyEvent(kind: kChar, rune: r)

proc summary*(ev: KeyEvent): string =
  ## Compact human-readable rendering of a KeyEvent. Used by the
  ## journal to label key-delivery events.
  case ev.kind
  of kChar: "Char(" & $ev.rune & ")"
  of kCtrl: "Ctrl-" & $ev.ch
  of kAlt:  "Alt-"  & $ev.ch
  else:     $ev.kind

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

proc parseCsi(params: string, final: char): KeyEvent =
  case final
  of 'A': atomKey(kArrowUp)
  of 'B': atomKey(kArrowDown)
  of 'C': atomKey(kArrowRight)
  of 'D': atomKey(kArrowLeft)
  of 'H': atomKey(kHome)
  of 'F': atomKey(kEnd)
  of '~': tildeKey(parseLeadingInt(params))
  else:   atomKey(kEscape)

proc parseSs3(c: char): KeyEvent =
  case c
  of 'P': atomKey(kF1)
  of 'Q': atomKey(kF2)
  of 'R': atomKey(kF3)
  of 'S': atomKey(kF4)
  of 'H': atomKey(kHome)
  of 'F': atomKey(kEnd)
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
