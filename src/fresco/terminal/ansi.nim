## ANSI escape sequence builders.
##
## Every proc here is pure: it returns a string. The caller decides when
## and where to emit (typically stderr — see DESIGN.md L5). Nothing in
## this module touches a file descriptor, terminal mode, or global state.

import std/unicode

const
  ESC = "\x1b"
  CSI = ESC & "["
  ## Internal — callers compose sequences via the named helpers below
  ## (`cursorTo`, `bold`, etc.) rather than concatenating raw escapes.

# --- Cursor positioning ----------------------------------------------------

proc cursorTo*(row, col: int): string =
  ## 1-based (row, col), per ECMA-48 CUP.
  CSI & $row & ";" & $col & "H"

proc cursorUp*(n: int = 1): string = CSI & $n & "A"
proc cursorDown*(n: int = 1): string = CSI & $n & "B"
proc cursorRight*(n: int = 1): string = CSI & $n & "C"
proc cursorLeft*(n: int = 1): string = CSI & $n & "D"

proc cursorColumn*(col: int): string = CSI & $col & "G"

proc saveCursor*(): string = ESC & "7"
proc restoreCursor*(): string = ESC & "8"

proc cursorHide*(): string = CSI & "?25l"
proc cursorShow*(): string = CSI & "?25h"

# --- Erasing ---------------------------------------------------------------

proc clearLine*(): string = CSI & "2K"
proc clearLineRight*(): string = CSI & "0K"
proc clearLineLeft*(): string = CSI & "1K"
proc clearScreen*(): string = CSI & "2J"
proc clearScreenBelow*(): string = CSI & "0J"

# --- Alternate screen ------------------------------------------------------

proc altScreenEnter*(): string = CSI & "?1049h"
proc altScreenLeave*(): string = CSI & "?1049l"

# --- Scroll region (DECSTBM) ----------------------------------------------
#
# CSI top;bot r sets the scroll region to rows [top, bot] (1-based,
# inclusive). Inside that region, IND (newline past bottom), RI
# (reverse-newline past top), CSI n S (scroll up), CSI n T (scroll
# down) shift the region's contents and discard rows pushed out.
# Rows outside the region are untouched.
#
# **Process-global state.** Setting the scroll region affects every
# subsequent terminal operation, so callers must reset it (CSI r)
# before continuing to paint other parts of the screen. fresco's
# render layer brackets every scroll emission with set/reset.

proc setScrollRegion*(top, bot: int): string =
  ## Confine subsequent scroll operations to rows [top, bot]
  ## (1-based inclusive). Cursor is moved to (1,1) after this by
  ## terminal convention; render layer compensates with an explicit
  ## CUP after the scroll command.
  CSI & $top & ";" & $bot & "r"

proc resetScrollRegion*(): string = CSI & "r"
  ## Restore the scroll region to the full screen.

proc scrollUp*(n: int = 1): string = CSI & $n & "S"
  ## Shift the current scroll region's contents up by `n` lines.
  ## Top `n` lines are discarded; bottom `n` lines blanked.

proc scrollDown*(n: int = 1): string = CSI & $n & "T"
  ## Shift the current scroll region's contents down by `n` lines.

# --- Styles / SGR ----------------------------------------------------------

type Color* = enum
  cBlack   = 0
  cRed     = 1
  cGreen   = 2
  cYellow  = 3
  cBlue    = 4
  cMagenta = 5
  cCyan    = 6
  cWhite   = 7
  cDefault = 9

proc reset*(): string = CSI & "0m"

proc bold*(s: string): string      = CSI & "1m" & s & CSI & "22m"
proc dim*(s: string): string       = CSI & "2m" & s & CSI & "22m"
proc italic*(s: string): string    = CSI & "3m" & s & CSI & "23m"
proc underline*(s: string): string = CSI & "4m" & s & CSI & "24m"
proc reverse*(s: string): string   = CSI & "7m" & s & CSI & "27m"

# ECMA-48 SGR offsets: 30..37 = 8-color foreground, 40..47 = background.
proc fg*(c: Color): string = CSI & $(30 + c.ord) & "m"
proc bg*(c: Color): string = CSI & $(40 + c.ord) & "m"

proc color*(s: string, c: Color): string =
  ## Wrap `s` with foreground color `c`, restoring the default fg after.
  fg(c) & s & CSI & "39m"

# --- Width-aware measurement ----------------------------------------------

proc isWide(r: Rune): bool =
  ## Approximate East Asian Width = Wide/Fullwidth. Covers the major CJK
  ## ranges + fullwidth forms. Emoji width is intentionally out of scope
  ## for v0 — DESIGN.md "Out of scope" calls out width-aware UTF-8 only.
  let v = r.int32
  (v >= 0x1100 and v <= 0x115F) or
  (v >= 0x2E80 and v <= 0x303E) or
  (v >= 0x3041 and v <= 0x33FF) or
  (v >= 0x3400 and v <= 0x4DBF) or
  (v >= 0x4E00 and v <= 0x9FFF) or
  (v >= 0xA000 and v <= 0xA4CF) or
  (v >= 0xAC00 and v <= 0xD7A3) or
  (v >= 0xF900 and v <= 0xFAFF) or
  (v >= 0xFE30 and v <= 0xFE4F) or
  (v >= 0xFF00 and v <= 0xFF60) or
  (v >= 0xFFE0 and v <= 0xFFE6) or
  (v >= 0x20000 and v <= 0x2FFFD) or
  (v >= 0x30000 and v <= 0x3FFFD)

proc isZeroWidth(r: Rune): bool =
  ## Returns true for runes that occupy zero display columns: combining marks,
  ## zero-width format characters, and variation selectors.
  let v = r.int32
  # Combining Diacritical Marks and other standard combining blocks
  (v >= 0x0300 and v <= 0x036F) or
  (v >= 0x1AB0 and v <= 0x1AFF) or
  (v >= 0x1DC0 and v <= 0x1DFF) or
  (v >= 0x20D0 and v <= 0x20FF) or
  (v >= 0xFE20 and v <= 0xFE2F) or
  # Zero-width format characters
  v == 0x200B or  # ZERO WIDTH SPACE
  v == 0x200C or  # ZERO WIDTH NON-JOINER
  v == 0x200D or  # ZERO WIDTH JOINER
  v == 0xFEFF or  # ZERO WIDTH NO-BREAK SPACE / BOM
  # Variation selectors
  (v >= 0xFE00 and v <= 0xFE0F) or
  (v >= 0xE0100 and v <= 0xE01EF)

proc displayWidth*(s: string): int =
  ## Rendered cell width of `s`. CSI/OSC escape sequences contribute 0
  ## cells; CJK wide runes count as 2; all other printable runes count
  ## as 1. Control bytes other than ESC are counted as 0.
  var i = 0
  while i < s.len:
    let b = s[i]
    if b == '\x1b':
      # ESC. Skip the rest of the sequence.
      inc i
      if i >= s.len: break
      case s[i]
      of '[':
        # CSI: ESC [ params... <final 0x40..0x7E>
        inc i
        while i < s.len and s[i].ord notin {0x40..0x7E}: inc i
        if i < s.len: inc i
      of ']', 'P', '^', '_':
        # OSC (ESC ]), DCS (ESC P), PM (ESC ^), APC (ESC _):
        # string sequences terminated by BEL or ST (ESC \).
        # Entire payload contributes 0 display columns.
        inc i
        while i < s.len:
          if s[i] == '\x07':
            inc i; break
          if s[i] == '\x1b' and i + 1 < s.len and s[i+1] == '\\':
            i += 2; break
          inc i
      of 'N', 'O':
        # SS2 (ESC N) / SS3 (ESC O): single-shift; introduces ONE further
        # character from the G2/G3 set.  Skip both the designator and that
        # introduced byte → 0 display columns for all three bytes.
        inc i  # skip designator
        if i < s.len: inc i  # skip introduced char
      else:
        # Two-byte ESC-something (e.g. ESC 7 / ESC 8).
        inc i
    elif b.ord < 0x20:
      inc i
    else:
      let r = s.runeAt(i)
      if not isZeroWidth(r):
        result += (if isWide(r): 2 else: 1)
      i += r.size

proc clipToWidth*(s: string, width: int): string =
  ## Return a prefix of `s` whose display width is at most `width` columns.
  ## ANSI escape sequences are copied through verbatim and do not consume
  ## display budget.  Wide runes that would overhang the boundary are replaced
  ## by a single space so no partial glyph is emitted.
  ## `width` ≤ 0 ⇒ `""`.
  if width <= 0: return ""
  # Fast path: string already fits.
  if displayWidth(s) <= width: return s
  var col = 0
  var i = 0
  while i < s.len:
    let b = s[i]
    if b == '\x1b':
      # Copy the escape sequence verbatim; it contributes 0 columns.
      let seqStart = i
      inc i
      if i >= s.len:
        result.add s[seqStart ..< i]
        break
      case s[i]
      of '[':
        inc i
        while i < s.len and s[i].ord notin {0x40..0x7E}: inc i
        if i < s.len: inc i
      of ']', 'P', '^', '_':
        inc i
        while i < s.len:
          if s[i] == '\x07':
            inc i; break
          if s[i] == '\x1b' and i + 1 < s.len and s[i+1] == '\\':
            i += 2; break
          inc i
      of 'N', 'O':
        inc i
        if i < s.len: inc i
      else:
        inc i
      result.add s[seqStart ..< i]
    elif b.ord < 0x20:
      # Non-ESC control byte — skip, don't emit.
      inc i
    else:
      let r = s.runeAt(i)
      let rw = if isZeroWidth(r): 0 elif isWide(r): 2 else: 1
      if rw == 0:
        # Zero-width: emit while budget not yet exhausted.
        if col < width:
          result.add s[i ..< i + r.size]
        i += r.size
      elif col + rw > width:
        # Would exceed budget.
        if rw == 2 and col + 1 == width:
          # Wide rune at the exact half-boundary: pad with a space.
          result.add ' '
        # Either way, stop.
        break
      else:
        result.add s[i ..< i + r.size]
        col += rw
        i += r.size
