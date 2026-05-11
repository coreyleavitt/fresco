## Single-line text input widget.
##
## v0 scope: ASCII / single-byte input only. CJK editing is deferred —
## the cursor is byte-indexed, and inserting a multi-byte rune still
## works correctly, but visual width on wide glyphs will be wrong.

import std/[unicode, strutils]
import chronos
import ../events
import ../input
import ../screen
import ../terminal/ansi

type
  InputOutcomeKind* = enum
    ioSubmitted
    ioCancelled

  InputOutcome* = object
    case kind*: InputOutcomeKind
    of ioSubmitted: text*: string
    of ioCancelled: discard

  History* = ref object
    entries*: seq[string]

proc newHistory*(): History = History(entries: @[])

proc renderInput(region: Region, prompt, text: string, cursor: int) =
  let pre   = if cursor > 0: text[0 ..< cursor] else: ""
  let atC   = if cursor < text.len: $text[cursor] else: " "
  let post  = if cursor + 1 < text.len: text[cursor + 1 .. ^1] else: ""
  region.set([prompt & pre & reverse(atC) & post])

proc inputLine*(stream: InputStream,
                screen: Screen,
                region: Region,
                prompt = "",
                initial = "",
                history: History = nil
               ): Future[InputOutcome]
               {.async: (raises: [CancelledError, Exception]).} =
  var text = initial
  var cursor = text.len
  # History view: index into history.entries, or .len for "stashed draft".
  var historyView =
    if history != nil: history.entries.len else: 0
  var stash = ""

  renderInput(region, prompt, text, cursor)
  screen.paint()

  while true:
    let ev = await stream.nextKey()
    case ev.kind
    of kEnter:
      if history != nil and text.len > 0:
        history.entries.add text
      return InputOutcome(kind: ioSubmitted, text: text)
    of kEscape:
      return InputOutcome(kind: ioCancelled)
    of kCtrl:
      case ev.ch
      of 'c':
        return InputOutcome(kind: ioCancelled)
      of 'u':
        text = ""
        cursor = 0
      of 'w':
        var i = cursor
        while i > 0 and text[i - 1] in {' ', '\t'}: dec i
        while i > 0 and text[i - 1] notin {' ', '\t'}: dec i
        text.delete(i ..< cursor)
        cursor = i
      of 'a':
        cursor = 0
      of 'e':
        cursor = text.len
      else: discard
    of kBackspace:
      if cursor > 0:
        text.delete(cursor - 1 ..< cursor)
        dec cursor
    of kDelete:
      if cursor < text.len:
        text.delete(cursor ..< cursor + 1)
    of kArrowLeft:
      if cursor > 0: dec cursor
    of kArrowRight:
      if cursor < text.len: inc cursor
    of kHome:
      cursor = 0
    of kEnd:
      cursor = text.len
    of kArrowUp:
      if history != nil and historyView > 0:
        if historyView == history.entries.len:
          stash = text
        dec historyView
        text = history.entries[historyView]
        cursor = text.len
    of kArrowDown:
      if history != nil and historyView < history.entries.len:
        inc historyView
        text =
          if historyView == history.entries.len: stash
          else: history.entries[historyView]
        cursor = text.len
    of kChar:
      let s = $ev.rune
      text.insert(s, cursor)
      cursor += s.len
    else: discard

    renderInput(region, prompt, text, cursor)
    screen.paint()
