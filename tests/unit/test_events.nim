import std/unittest
import std/unicode
import fresco/events

template oneEvent(input: string, expected: KeyEvent) =
  let (evs, consumed) = decode(input)
  check evs.len == 1
  check evs[0] == expected
  check consumed == input.len

suite "single-byte keys":

  test "printable ASCII becomes kChar":
    oneEvent "a", charKey(Rune('a'))
    oneEvent "Z", charKey(Rune('Z'))
    oneEvent " ", charKey(Rune(' '))

  test "CR and LF both decode as Enter":
    oneEvent "\r", atomKey(kEnter)
    oneEvent "\n", atomKey(kEnter)

  test "Tab":
    oneEvent "\t", atomKey(kTab)

  test "Backspace via BS (0x08) and DEL (0x7F)":
    oneEvent "\x08", atomKey(kBackspace)
    oneEvent "\x7F", atomKey(kBackspace)

  test "Ctrl+letter maps to lowercase":
    oneEvent "\x01", ctrlKey('a')
    oneEvent "\x03", ctrlKey('c')
    oneEvent "\x1A", ctrlKey('z')

  test "Ctrl+@ from NUL":
    oneEvent "\x00", ctrlKey('@')

suite "Escape and Alt disambiguation":

  test "bare ESC without finalize is held as partial":
    let (evs, consumed) = decode("\x1b")
    check evs.len == 0
    check consumed == 0

  test "bare ESC with finalize emits kEscape":
    let (evs, consumed) = decode("\x1b", finalize = true)
    check evs == @[atomKey(kEscape)]
    check consumed == 1

  test "ESC + printable is Alt+char":
    oneEvent "\x1ba", altKey('a')
    oneEvent "\x1bZ", altKey('Z')

  test "ESC ESC emits Escape then re-parses":
    let (evs, consumed) = decode("\x1b\x1ba")
    check evs == @[atomKey(kEscape), altKey('a')]
    check consumed == 3

suite "CSI sequences":

  test "arrow keys":
    oneEvent "\x1b[A", atomKey(kArrowUp)
    oneEvent "\x1b[B", atomKey(kArrowDown)
    oneEvent "\x1b[C", atomKey(kArrowRight)
    oneEvent "\x1b[D", atomKey(kArrowLeft)

  test "Home / End — short form":
    oneEvent "\x1b[H", atomKey(kHome)
    oneEvent "\x1b[F", atomKey(kEnd)

  test "tilde-terminated keys":
    oneEvent "\x1b[1~", atomKey(kHome)
    oneEvent "\x1b[2~", atomKey(kInsert)
    oneEvent "\x1b[3~", atomKey(kDelete)
    oneEvent "\x1b[4~", atomKey(kEnd)
    oneEvent "\x1b[5~", atomKey(kPageUp)
    oneEvent "\x1b[6~", atomKey(kPageDown)
    oneEvent "\x1b[7~", atomKey(kHome)
    oneEvent "\x1b[8~", atomKey(kEnd)

  test "F5..F12 use tilde form":
    oneEvent "\x1b[15~", atomKey(kF5)
    oneEvent "\x1b[17~", atomKey(kF6)
    oneEvent "\x1b[24~", atomKey(kF12)

  test "tilde sequence with modifier params still decodes base key":
    oneEvent "\x1b[5;2~", atomKey(kPageUp)

suite "SS3 (F1..F4)":

  test "ESC O P/Q/R/S → F1..F4":
    oneEvent "\x1bOP", atomKey(kF1)
    oneEvent "\x1bOQ", atomKey(kF2)
    oneEvent "\x1bOR", atomKey(kF3)
    oneEvent "\x1bOS", atomKey(kF4)

  test "SS3 Home / End":
    oneEvent "\x1bOH", atomKey(kHome)
    oneEvent "\x1bOF", atomKey(kEnd)

suite "partial-sequence carryover":

  test "incomplete CSI is left unconsumed":
    let (evs, consumed) = decode("\x1b[")
    check evs.len == 0
    check consumed == 0

  test "incomplete CSI after a complete event yields just the event":
    let (evs, consumed) = decode("a\x1b[1")
    check evs == @[charKey(Rune('a'))]
    check consumed == 1

  test "incomplete SS3 left unconsumed":
    let (evs, consumed) = decode("\x1bO")
    check evs.len == 0
    check consumed == 0

  test "completing a carried partial across two calls":
    let part1 = "\x1b["
    let (evs1, c1) = decode(part1)
    check c1 == 0
    let part2 = part1 & "A"
    let (evs2, c2) = decode(part2)
    check evs2 == @[atomKey(kArrowUp)]
    check c2 == part2.len

suite "UTF-8":

  test "CJK rune decodes to single kChar":
    let (evs, consumed) = decode("漢")
    check evs.len == 1
    check evs[0].kind == kChar
    check evs[0].rune == "漢".runeAt(0)
    check consumed == "漢".len

  test "partial UTF-8 lead byte is left unconsumed":
    let full = "漢"
    let partial = full[0 ..< full.len - 1]
    let (evs, consumed) = decode(partial)
    check evs.len == 0
    check consumed == 0
