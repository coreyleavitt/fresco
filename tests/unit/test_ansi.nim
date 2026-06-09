import std/unittest
import std/strutils
import fresco/terminal/ansi

suite "ANSI cursor + erase":

  test "cursorTo emits CUP with 1-based row/col":
    check cursorTo(1, 1)   == "\x1b[1;1H"
    check cursorTo(10, 20) == "\x1b[10;20H"

  test "cursor relative motion":
    check cursorUp(3)    == "\x1b[3A"
    check cursorDown()   == "\x1b[1B"
    check cursorRight(2) == "\x1b[2C"
    check cursorLeft(5)  == "\x1b[5D"
    check cursorColumn(1) == "\x1b[1G"

  test "save / restore cursor use DECSC/DECRC":
    check saveCursor()    == "\x1b7"
    check restoreCursor() == "\x1b8"

  test "cursor visibility":
    check cursorHide() == "\x1b[?25l"
    check cursorShow() == "\x1b[?25h"

  test "line + screen erase":
    check clearLine()         == "\x1b[2K"
    check clearLineRight()    == "\x1b[0K"
    check clearLineLeft()     == "\x1b[1K"
    check clearScreen()       == "\x1b[2J"
    check clearScreenBelow()  == "\x1b[0J"

  test "alternate screen":
    check altScreenEnter() == "\x1b[?1049h"
    check altScreenLeave() == "\x1b[?1049l"

suite "ANSI styles":

  test "reset SGR":
    check reset() == "\x1b[0m"

  test "style wrappers open and close their own attribute":
    check bold("x")      == "\x1b[1m" & "x" & "\x1b[22m"
    check dim("x")       == "\x1b[2m" & "x" & "\x1b[22m"
    check italic("x")    == "\x1b[3m" & "x" & "\x1b[23m"
    check underline("x") == "\x1b[4m" & "x" & "\x1b[24m"
    check reverse("x")   == "\x1b[7m" & "x" & "\x1b[27m"

  test "fg / bg color SGR codes":
    check fg(cRed)     == "\x1b[31m"
    check fg(cGreen)   == "\x1b[32m"
    check fg(cDefault) == "\x1b[39m"
    check bg(cBlue)    == "\x1b[44m"
    check bg(cDefault) == "\x1b[49m"

  test "color() wraps and restores default fg":
    check color("hi", cGreen) == "\x1b[32mhi\x1b[39m"

suite "displayWidth":

  test "ASCII counts one cell per byte":
    check displayWidth("")      == 0
    check displayWidth("hello") == 5

  test "CSI sequences contribute zero cells":
    check displayWidth("\x1b[31mred\x1b[0m") == 3
    check displayWidth(bold("hi"))           == 2
    check displayWidth(color("ok", cCyan))   == 2

  test "two-byte ESC (DECSC/DECRC) contributes zero cells":
    check displayWidth(saveCursor() & "a" & restoreCursor()) == 1

  test "OSC terminated by BEL or ST contributes zero cells":
    check displayWidth("\x1b]0;title\x07x")    == 1
    check displayWidth("\x1b]0;title\x1b\\x")  == 1

  test "CJK wide runes count as two cells":
    check displayWidth("漢字")  == 4
    check displayWidth("a漢b") == 4
    check displayWidth("한")    == 2

  test "combining marks (U+0300 block) count as zero cells":
    # U+0301 COMBINING ACUTE ACCENT — base 'e' is 1 cell, combiner adds 0
    let eAcute = "e" & "\xCC\x81"   # U+0301 in UTF-8
    check displayWidth(eAcute) == 1
    # 5-letter word with one combining mark still measures 5
    let word = "caf" & "\xCC\x81" & "e"   # café with combiner separate
    check displayWidth(word) == 4

  test "ZWJ (U+200D) between base runes counts zero cells":
    # U+200D in UTF-8 is \xE2\x80\x8D
    let joined = "a" & "\xE2\x80\x8D" & "b"
    check displayWidth(joined) == 2

  test "variation selector (U+FE0F) after base char counts zero cells":
    # U+FE0F VARIATION SELECTOR-16 in UTF-8 is \xEF\xB8\x8F
    let withVS = "a" & "\xEF\xB8\x8F"
    check displayWidth(withVS) == 1

  test "SS2 (ESC N + one char) contributes zero cells":
    # ESC N x — SS2 single-shift introduces one char from G2; all 3 bytes → 0
    check displayWidth("a" & "\x1bNx" & "b") == 2
    check displayWidth("\x1bNx") == 0

  test "SS3 (ESC O + one char) contributes zero cells":
    # ESC O x — SS3 single-shift; same treatment as SS2
    check displayWidth("a" & "\x1bOx" & "b") == 2
    check displayWidth("\x1bOx") == 0

  test "DCS string sequence (ESC P ... ST) contributes zero cells":
    # ESC P payload ESC \  — all bytes → 0 display columns
    check displayWidth("\x1bP1;2;3|payload\x1b\\" & "x") == 1
    # BEL-terminated DCS
    check displayWidth("\x1bPdata\x07y") == 1

  test "APC (ESC _) and PM (ESC ^) string sequences contribute zero cells":
    # APC: ESC _ ... ESC \
    check displayWidth("\x1b_appcmd\x1b\\" & "z") == 1
    # PM: ESC ^ ... ESC \
    check displayWidth("\x1b^privmsg\x1b\\" & "w") == 1

suite "physicalRows":

  test "exact-width line measures as 1 row":
    # dw == width: exactly fills one row, no wrap
    let line = "hello"  # displayWidth == 5
    check physicalRows(line, 5) == 1

  test "width+1 wraps to 2 rows":
    # dw == 6, width == 5: just over one wrap boundary
    let line = "hello!"  # displayWidth == 6
    check physicalRows(line, 5) == 2

  test "multi-row case (3x width)":
    # dw == 15, width == 5: exactly 3 rows
    let line = "aaaaabbbbbccccc"  # displayWidth == 15
    check physicalRows(line, 5) == 3

  test "pure-SGR line (zero displayWidth) measures to 1 row":
    # max(1, ...) guard: a line that is all escape sequences still
    # advances at least 1 physical row
    check physicalRows("\x1b[31m\x1b[0m", 80) == 1
    check physicalRows("", 80) == 1

  test "ceil-not-floor: dw=5 width=3 gives 2":
    # floor(5/3)==1, ceil(5/3)==2
    let line = "abcde"  # displayWidth == 5
    check physicalRows(line, 3) == 2

  test "width <= 0 returns 1 (divide-by-zero guard)":
    check physicalRows("hello", 0)  == 1
    check physicalRows("hello", -1) == 1

suite "clipToWidth":

  test "plain ASCII truncation":
    check clipToWidth("hello", 3) == "hel"

  test "no-op when already <= width":
    check clipToWidth("hi", 5) == "hi"

  test "wide chars counted as 2":
    check clipToWidth("漢字", 2) == "漢"
    check clipToWidth("a漢b", 3) == "a漢"

  test "wide-char-at-boundary pads with space":
    check clipToWidth("漢", 1) == " "

  test "escape passthrough uncounted - no-op case":
    let styled = "\x1b[31mred\x1b[0m"
    check clipToWidth(styled, 5) == styled

  test "escape passthrough uncounted - truncation case":
    let styled = "\x1b[31mredish\x1b[0m"
    let clipped = clipToWidth(styled, 3)
    check clipped.startsWith("\x1b[31mred")
    check displayWidth(clipped) == 3

  test "width 0 returns empty string":
    check clipToWidth("hello", 0) == ""
    check clipToWidth("", 0) == ""

  test "width 1 with plain char returns one char":
    check clipToWidth("abc", 1) == "a"

  test "negative width returns empty string":
    check clipToWidth("hello", -1) == ""

  # --- slice 1b: reset-on-cut + OSC-8 close ---

  test "styled cut appends SGR reset":
    let clipped = clipToWidth("\x1b[31mredish\x1b[0m", 3)
    check clipped.startsWith("\x1b[31mred")
    check clipped.endsWith("\x1b[0m")
    check displayWidth(clipped) == 3

  test "conservative double-SGR cut still appends reset":
    let clipped = clipToWidth("\x1b[1m\x1b[22mlongtext", 3)
    check clipped.endsWith("\x1b[0m")

  test "no SGR - no reset appended":
    check clipToWidth("plaintext", 3) == "pla"

  test "uncut styled string returned unchanged":
    let s = "\x1b[31mhi\x1b[0m"
    check clipToWidth(s, 10) == s

  test "OSC-8 hyperlink cut mid-text gets closed":
    # Link open: ESC ] 8 ; ; http://x ESC \
    # Link text: linktext
    # Link close: ESC ] 8 ; ; ESC \
    let linkOpen  = "\x1b]8;;http://x\x1b\\"
    let linkClose = "\x1b]8;;\x1b\\"
    let input = linkOpen & "linktext" & linkClose
    let clipped = clipToWidth(input, 3)
    # Must start with the link-open and have "lin"
    check clipped.startsWith(linkOpen)
    check clipped.contains("lin")
    # Must contain the OSC-8 close (no SGR was open, so no SGR reset)
    check clipped.contains(linkClose)
    check displayWidth(clipped) == 3

suite "sanitizeLogLine":

  test "C0 control bytes are stripped (newline, CR, tab, backspace, BEL)":
    check sanitizeLogLine("a\nb") == "ab"
    check sanitizeLogLine("x\ty") == "xy"
    check sanitizeLogLine("a\rb") == "ab"
    check sanitizeLogLine("a\bb") == "ab"
    check sanitizeLogLine("a\x07b") == "ab"

  test "SGR CSI sequences are kept":
    check sanitizeLogLine("\x1b[31mred\x1b[0m") == "\x1b[31mred\x1b[0m"

  test "motion CSI stripped, surrounding text kept":
    check sanitizeLogLine("a\x1b[2Hb") == "ab"
    check sanitizeLogLine("a\x1b[2Jb") == "ab"

  test "title OSC stripped (BEL and ST terminated)":
    check sanitizeLogLine("a\x1b]0;title\x07b") == "ab"
    check sanitizeLogLine("a\x1b]0;title\x1b\\b") == "ab"

  test "OSC-8 hyperlinks kept":
    let osc8 = "\x1b]8;;https://x\x1b\\link\x1b]8;;\x1b\\"
    check sanitizeLogLine(osc8) == osc8

  test "plain UTF-8 passes through unchanged":
    check sanitizeLogLine("héllo") == "héllo"
    check sanitizeLogLine("日本") == "日本"

  test "DEL (0x7F) is stripped":
    check sanitizeLogLine("a\x7fb") == "ab"

  test "idempotence: sanitize(sanitize(x)) == sanitize(x)":
    let mixed = "abc\x1b[31mred\x1b[0m\n\t\x1b]0;title\x07\x1b]8;;http://x\x1b\\link\x1b]8;;\x1b\\"
    let once = sanitizeLogLine(mixed)
    check sanitizeLogLine(once) == once

  # --- DCS / PM / APC / SS2 / SS3 ---

  test "DCS (ESC P ... ST) stripped, surrounding text survives":
    check sanitizeLogLine("a\x1bPdcs-payload\x1b\\b") == "ab"
    check sanitizeLogLine("a\x1bPdcs-bel\x07b") == "ab"

  test "PM (ESC ^ ... ST) stripped, surrounding text survives":
    check sanitizeLogLine("a\x1b^pm-payload\x1b\\b") == "ab"

  test "APC (ESC _ ... ST) stripped, surrounding text survives":
    check sanitizeLogLine("a\x1b_apc-payload\x1b\\b") == "ab"

  test "SS2 (ESC N x) stripped, surrounding text survives":
    check sanitizeLogLine("a\x1bNxb") == "ab"

  test "SS3 (ESC O x) stripped, surrounding text survives":
    check sanitizeLogLine("a\x1bOxb") == "ab"

  test "lone trailing ESC stripped":
    check sanitizeLogLine("a\x1b") == "a"

  test "truncated CSI (no final byte before end) stripped":
    check sanitizeLogLine("a\x1b[123") == "a"

  # --- C1 controls (8-bit, 0x80..0x9F) — H2 security fix ---

  test "8-bit CSI (0x9B) stripped — H2":
    # \x9b is 8-bit CSI (≡ ESC [); params+final byte are consumed too.
    # \x9b2J = 8-bit-CSI "2J" (erase screen) — full sequence stripped.
    check sanitizeLogLine("a\x9b2Jb") == "ab"
    # \x9bb: 'b' (0x62) is in the CSI final-byte range (0x40..0x7E) so the
    # entire sequence \x9bb is consumed — the 'b' is NOT printable here.
    check sanitizeLogLine("a\x9bb") == "a"
    # Bare \x9b with no following byte — stripped (lone C1).
    check sanitizeLogLine("a\x9b") == "a"

  test "8-bit OSC (0x9D) stripped — H2":
    # BEL-terminated payload consumed; following 'b' is printable.
    check sanitizeLogLine("a\x9dclipboard-write\x07b") == "ab"
    # ST-terminated variant.
    check sanitizeLogLine("a\x9dclipboard-write\x1b\\b") == "ab"

  test "8-bit DCS (0x90) stripped — H2":
    # 'b' after 0x90 is DCS payload until ST — strip whole sequence.
    # Use a proper ST-terminated sequence so the text after ST is printable.
    check sanitizeLogLine("a\x90payload\x1b\\b") == "ab"
    check sanitizeLogLine("a\x90payload\x07b") == "ab"

  test "8-bit PM (0x9E) stripped — H2":
    check sanitizeLogLine("a\x9epayload\x1b\\b") == "ab"

  test "8-bit APC (0x9F) stripped — H2":
    check sanitizeLogLine("a\x9fpayload\x1b\\b") == "ab"

  test "stray UTF-8 continuation byte (0xA5) at start position stripped — H2":
    check sanitizeLogLine("a\xa5b") == "ab"

  test "valid multibyte UTF-8 passes through unchanged — H2 regression":
    # café (U+00E9 = 0xC3 0xA9), Japanese, emoji codepoint
    check sanitizeLogLine("café") == "café"
    check sanitizeLogLine("日本語") == "日本語"
    check sanitizeLogLine("hello\xC3\xA9world") == "hello\xC3\xA9world"

  test "C1 output contains no byte in 0x80..0x9F — H2 invariant":
    let inputs = [
      "a\x80b", "a\x85b", "a\x8fb", "a\x90payload\x1b\\b",
      "a\x9b2Jb", "a\x9cb", "a\x9dclip\x07b", "a\x9epayload\x1b\\b",
      "a\x9fpayload\x1b\\b", "a\xa0b",
    ]
    for s in inputs:
      let sanitized = sanitizeLogLine(s)
      # Walk start positions only — skip continuation bytes of valid UTF-8
      # multibyte sequences so we don't falsely flag them.
      var i = 0
      while i < sanitized.len:
        let b = sanitized[i].ord
        if b >= 0xC0:
          # UTF-8 lead byte: skip the full sequence
          let rlen = if b >= 0xF0: 4 elif b >= 0xE0: 3 else: 2
          i += rlen
        else:
          check b < 0x80 or b > 0x9F
          inc i

  # --- Security-3: 8-bit ST (0x9C) as string-sequence terminator ---

  test "Security-3: 8-bit ST (0x9C) terminates 8-bit OSC body — KEEP after 0x9C":
    # 0x9D is 8-bit OSC; "title" is the body; 0x9C is the 8-bit ST terminator.
    # Everything AFTER the 0x9C byte is not part of the sequence and must be kept.
    check sanitizeLogLine("\x9dtitle\x9cKEEP") == "KEEP"

  test "Security-3: 8-bit ST (0x9C) terminates 8-bit DCS body — KEEP after 0x9C":
    check sanitizeLogLine("\x90payload\x9cKEEP") == "KEEP"

  test "Security-3: 8-bit ST (0x9C) terminates 8-bit PM body — KEEP after 0x9C":
    check sanitizeLogLine("\x9epayload\x9cKEEP") == "KEEP"

  test "Security-3: 8-bit ST (0x9C) terminates 8-bit APC body — KEEP after 0x9C":
    check sanitizeLogLine("\x9fpayload\x9cKEEP") == "KEEP"

  test "Security-3: 0x9C alone (no preceding string introducer) is stripped (single-byte C1)":
    # 0x9C standing alone (no OSC/DCS/PM/APC before it) is just a lone
    # single-byte C1 control — it gets consumed by the `else: discard` branch.
    check sanitizeLogLine("a\x9cb") == "ab"

# --- Security-1: clipToWidth C1 body-scan completeness ---

suite "clipToWidth Security-1: C1 body bytes fully consumed":

  test "Security-1: 8-bit OSC terminated by BEL — body bytes not emitted, text after BEL kept":
    # 0x9D is 8-bit OSC; body is "title"; terminated by BEL (0x07); "X" follows.
    # The entire OSC sequence is consumed (stripped); "X" must appear in output.
    let s = "\x9dtitle\x07" & "X"
    let clipped = clipToWidth(s, 5)
    check clipped.contains("X")
    check not clipped.contains("\x9d")
    check not clipped.contains("title")

  test "Security-1: 8-bit CSI (0x9B) body + final byte not emitted as text":
    # "\x9b2J" is an 8-bit CSI erase-screen sequence (final byte 'J' in 0x40..0x7E).
    # Body "2" and final "J" must be consumed, not emitted; "Y" follows and must survive.
    let s = "\x9b2J" & "Y"
    let clipped = clipToWidth(s, 5)
    check clipped.contains("Y")
    check not clipped.contains("\x9b")

  test "Security-1: 8-bit OSC terminated by 0x9C — content after 0x9C emitted":
    # 0x9D "title" 0x9C terminates by 8-bit ST; "X" follows and must appear.
    let s = "\x9dtitle\x9c" & "X"
    let clipped = clipToWidth(s, 5)
    check clipped.contains("X")
    check not clipped.contains("\x9d")
    check not clipped.contains("title")

  test "Security-1: unterminated 8-bit OSC consumes to end of string (safe)":
    # An unterminated OSC (no BEL/ST/0x9C) gobbles the rest of the string.
    # This is the correct/safe behavior: nothing from the unterminated body leaks.
    # The body "\x1b[H" looks like a 7-bit escape but it is inside the OSC body
    # and must NOT be re-processed as a 7-bit CSI sequence.
    let s = "\x9d\x1b[H"  # unterminated: no BEL, no ST, no 0x9C
    let clipped = clipToWidth(s, 5)
    # The entire string is consumed as one unterminated sequence; output is empty.
    check clipped == ""
    check not clipped.contains("\x1b[H")
