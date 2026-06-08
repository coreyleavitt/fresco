## tests/unit/test_clip_proptest.nim — slice 1c: clipToWidth proptest invariants.
##
## Three properties pinned via proptest choice-sequence engine:
##   P1  Width bound       — displayWidth(clipToWidth(s, w)) <= w
##   P2  Idempotence       — clipToWidth twice == clipToWidth once
##   P3  No split escapes  — output has no truncated CSI/OSC, no unclosed OSC-8
##
## Generator: plain ASCII + embedded ANSI (SGR + OSC-8 hyperlinks) so the
## open-OSC hygiene code path is exercised on every run.

import std/unittest
import proptest
import fresco/terminal/ansi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc hasNoSplitEscapes(s: string): bool =
  ## Returns true iff:
  ##   • every CSI (ESC [) reaches a final byte in 0x40..0x7E within the string
  ##   • every OSC-8 hyperlink open (ESC ] 8 ; ... <uri> <term>) is matched
  ##     by a close (ESC ] 8 ;; <term>) before end-of-string
  var i = 0
  var osc8Open = false
  while i < s.len:
    let b = s[i]
    if b == '\x1b':
      inc i
      if i >= s.len:
        return false   # truncated ESC at end — malformed
      case s[i]
      of '[':
        # CSI: must reach a final byte in 0x40..0x7E
        inc i
        while i < s.len and s[i].ord notin {0x40..0x7E}: inc i
        if i >= s.len:
          return false  # CSI never closed
        inc i  # consume final byte
      of ']', 'P', '^', '_':
        let intro = s[i]
        inc i
        let payloadStart = i
        # scan to BEL or ST
        var terminated = false
        while i < s.len:
          if s[i] == '\x07':
            inc i; terminated = true; break
          if s[i] == '\x1b' and i + 1 < s.len and s[i+1] == '\\':
            i += 2; terminated = true; break
          inc i
        if not terminated:
          return false  # OSC/DCS never closed
        # Track OSC-8 state
        if intro == ']':
          let termLen = if i >= 2 and s[i-1] == '\\': 2
                        elif i >= 1 and s[i-1] == '\x07': 1
                        else: 0
          let payload = s[payloadStart ..< i - termLen]
          if payload.len >= 2 and payload[0] == '8' and payload[1] == ';':
            var semi2 = 2
            while semi2 < payload.len and payload[semi2] != ';': inc semi2
            if semi2 < payload.len:
              let uri = payload[semi2 + 1 ..< payload.len]
              osc8Open = uri.len > 0
      of 'N', 'O':
        inc i
        if i < s.len: inc i
      else:
        inc i  # two-byte ESC-x sequence
    else:
      inc i
  # After scanning the whole string, no OSC-8 should be left open
  result = not osc8Open

# ---------------------------------------------------------------------------
# ANSI+OSC-8 string generator
# ---------------------------------------------------------------------------
# Builds a string that interleaves plain ASCII text with:
#   - SGR colour sequences (ESC [ 3x m / ESC [0m)
#   - OSC-8 hyperlink open (ESC ] 8 ;; https://x ST)
#   - OSC-8 hyperlink close (ESC ] 8 ;; ST) matching the open
# This is expressed as a custom strategy using proptest's newStrategy escape
# hatch + integer/string/boolean draws.

proc ansiStringStrategy(): Strategy[string] =
  newStrategy(proc(src: var DataSource): string =
    # Number of segments (0..4)
    let nSegs = src.drawInteger(toInt128(0), toInt128(4), toInt128(0)).toInt64.int
    var acc = ""
    var osc8IsOpen = false
    for seg in 0 ..< nSegs:
      # Kind: 0=plain text, 1=SGR colour, 2=OSC-8 open, 3=OSC-8 close
      let kind = src.drawInteger(toInt128(0), toInt128(3), toInt128(0)).toInt64.int
      case kind
      of 0:
        # Plain ASCII word (1..6 chars from a..z)
        let len = src.drawInteger(toInt128(1), toInt128(6), toInt128(1)).toInt64.int
        let raw = src.drawString(intervals([(0x61'i32, 0x7a'i32)]), len, len)
        acc.add raw
      of 1:
        # SGR: pick colour 31..36
        let c = src.drawInteger(toInt128(31), toInt128(36), toInt128(31)).toInt64.int
        acc.add "\x1b[" & $c & "m"
        # optionally close with reset
        if src.drawBoolean(0.5):
          acc.add "\x1b[0m"
      of 2:
        # OSC-8 open — only if not already open
        if not osc8IsOpen:
          acc.add "\x1b]8;;https://example.com\x1b\\"
          osc8IsOpen = true
      of 3:
        # OSC-8 close — only if open, so the generator never produces a
        # structurally invalid *source* string (properties are about output)
        if osc8IsOpen:
          acc.add "\x1b]8;;\x1b\\"
          osc8IsOpen = false
      else: discard
    # Always close an open hyperlink at the end of the generator so the
    # *input* itself is well-formed (we're not testing malformed-input
    # handling here — that's for a separate robustness suite).
    if osc8IsOpen:
      acc.add "\x1b]8;;\x1b\\"
    acc
  )

# ---------------------------------------------------------------------------
# Properties
# ---------------------------------------------------------------------------

suite "clipToWidth — proptest invariants":

  property "P1 width bound: displayWidth(clipToWidth(s, w)) <= w":
    with Settings(maxExamples: 300, testId: "clip-width-bound")
    given s in ansiStringStrategy(),
          w in integers(0, 40)
    ensure displayWidth(clipToWidth(s, w)) <= w

  property "P2 idempotence: clipping twice == clipping once":
    with Settings(maxExamples: 300, testId: "clip-idempotent")
    given s in ansiStringStrategy(),
          w in integers(0, 40)
    let once = clipToWidth(s, w)
    ensure clipToWidth(once, w) == once

  property "P3 no split escapes, no unclosed OSC-8 in output":
    with Settings(maxExamples: 300, testId: "clip-no-split-escapes")
    given s in ansiStringStrategy(),
          w in integers(0, 40)
    ensure hasNoSplitEscapes(clipToWidth(s, w))
