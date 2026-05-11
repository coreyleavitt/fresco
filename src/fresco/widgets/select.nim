## Single-select menu widget.
##
## Recall's permission prompt is the first consumer; future confirm /
## review screens reuse the same primitive. Navigation: ↑/↓ arrows or
## j/k, number keys 1..9 jump directly. Enter confirms. Ctrl-C or Esc
## cancels. `/` switches to slash-command mode — a single-line input
## whose Enter returns the typed string.
##
## API is return-value (variant) rather than callback: cleaner with
## chronos and easier to test. Callers `case outcome.kind of ...`.

import std/unicode
import chronos
import ../events
import ../input
import ../screen
import ../terminal/ansi

type
  SelectOutcomeKind* = enum
    soChosen
    soCancelled
    soSlashCommand

  SelectOutcome* = object
    case kind*: SelectOutcomeKind
    of soChosen:       index*: int
    of soCancelled:    discard
    of soSlashCommand: command*: string

proc renderMenu(region: Region,
                options: openArray[string],
                selected: int,
                slashMode: bool,
                slashBuf: string) =
  var rows: seq[string] = @[]
  for i, opt in options:
    let marker = if i == selected: color("> ", cCyan) else: "  "
    let body   = if i == selected: bold(opt) else: opt
    rows.add marker & $(i + 1) & ". " & body
  if slashMode:
    rows.add color("/", cYellow) & slashBuf
  region.set(rows)

proc selectMenu*(stream: InputStream,
                 screen: Screen,
                 region: Region,
                 options: seq[string]
                ): Future[SelectOutcome]
                {.async: (raises: [CancelledError, Exception]).} =
  ## Drive the menu loop. Returns when the user picks, cancels, or
  ## submits a slash-command. Each iteration of the input loop redraws
  ## via `screen.paint()`.
  doAssert options.len > 0, "selectMenu: empty options"

  var selected = 0
  var slashMode = false
  var slashBuf = ""

  renderMenu(region, options, selected, slashMode, slashBuf)
  screen.paint()

  while true:
    let ev = await stream.nextKey()

    if slashMode:
      case ev.kind
      of kEnter:
        return SelectOutcome(kind: soSlashCommand, command: slashBuf)
      of kEscape:
        slashMode = false
        slashBuf = ""
      of kBackspace:
        if slashBuf.len > 0: slashBuf.setLen(slashBuf.len - 1)
      of kCtrl:
        if ev.ch == 'c': return SelectOutcome(kind: soCancelled)
      of kChar:
        slashBuf.add $ev.rune
      else: discard
    else:
      case ev.kind
      of kArrowUp:
        if selected > 0: dec selected
      of kArrowDown:
        if selected < options.high: inc selected
      of kEnter:
        return SelectOutcome(kind: soChosen, index: selected)
      of kEscape:
        return SelectOutcome(kind: soCancelled)
      of kCtrl:
        if ev.ch == 'c': return SelectOutcome(kind: soCancelled)
      of kChar:
        let s = $ev.rune
        if s == "j" and selected < options.high: inc selected
        elif s == "k" and selected > 0: dec selected
        elif s == "/":
          slashMode = true
          slashBuf = ""
        elif s.len == 1 and s[0] in '1'..'9':
          let idx = s[0].ord - ord('1')
          if idx < options.len:
            return SelectOutcome(kind: soChosen, index: idx)
      else: discard

    renderMenu(region, options, selected, slashMode, slashBuf)
    screen.paint()
