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
      of ']':
        # OSC: ESC ] ... (BEL | ESC \)
        inc i
        while i < s.len:
          if s[i] == '\x07':
            inc i; break
          if s[i] == '\x1b' and i + 1 < s.len and s[i+1] == '\\':
            i += 2; break
          inc i
      else:
        # Two-byte ESC-something (e.g. ESC 7 / ESC 8).
        inc i
    elif b.ord < 0x20:
      inc i
    else:
      let r = s.runeAt(i)
      result += (if isWide(r): 2 else: 1)
      i += r.size
