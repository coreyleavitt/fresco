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
