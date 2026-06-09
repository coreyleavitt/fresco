## Inline REPL demo — InlineScreen surface type.
##
## Demonstrates the InlineScreen "modern-CLI" shape: a bottom-anchored
## live band (prompt row + 1-row status header via pinnedHeaderRows=2) with
## committed scrollback spilling into native terminal history above it.
##
## Interaction:
##   - Type printable characters; they accumulate into a line buffer shown
##     in the live prompt row.
##   - Press Enter: the buffered line is committed to scrollback via
##     `appendLine` + `commit`, scrolling up into native terminal history.
##     The live prompt repaints at the bottom.
##   - Backspace: removes the last character from the line buffer.
##   - Ctrl-C / Ctrl-D: quit cleanly. The `withInlineScreen` lifecycle
##     template guarantees teardownFlush is called on every exit path
##     (normal return, exception, or graceful SIGTERM/SIGINT via the watch
##     task) — zero consumer plumbing required.
##
## Scope: this is a visual demo, not a full line editor. There is no cursor
## movement within the line, no kill-line, no history navigation — only
## append + backspace. Add those via a dedicated line-editor layer for
## production use.
##
## Visual check: type a line and press Enter — the typed text scrolls into
## terminal history above while the prompt stays pinned at the bottom. Press
## Shift-PgUp to confirm your scrollback still contains the committed lines.
## Ctrl-C quits with the terminal fully restored (no wedged raw mode).
##
## Run:
##   ./dev shell
##   nim r --hints:off --path:src examples/inline_prompt.nim

import std/unicode
import chronos
import fresco/input as fi
import fresco/events
import fresco/inline_screen
import fresco/inline_teardown
import fresco/render/sink/terminal

# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------

proc app(stream: InputStream, s: InlineScreen[TerminalSink])
        {.async: (raises: [CancelledError, Exception]).} =
  ## Interactive loop: type a line, Enter commits it to scrollback.

  var lineBuffer = ""

  # Pinned live band: row 0 = status header, row 1 = prompt.
  # pinnedHeaderRows=2, so liveZoneHeight = h - 2.
  let header = s.newRegion(0, 0, 1, s.width)
  let prompt  = s.newRegion(1, 0, 1, s.width)

  proc updatePrompt() =
    header.setRow(0, "inline_prompt demo  [Enter] commit  [Backspace] erase  [Ctrl-C/D] quit")
    prompt.setRow(0, "> " & lineBuffer & "_")
    s.paint()

  # Initial paint.
  updatePrompt()

  while true:
    let ev = await stream.nextKey()
    case ev.kind
    of kChar:
      if modCtrl in ev.modifiers:
        # Ctrl-C or Ctrl-D → quit.
        if ev.rune == Rune('c') or ev.rune == Rune('d'):
          break
        # Ignore other Ctrl combos.
      else:
        lineBuffer &= $ev.rune
        updatePrompt()
    of kEnter:
      let committed = lineBuffer
      lineBuffer = ""
      # appendLine enqueues into scrollback; commit spills it into history.
      s.appendLine(committed)
      discard s.commit()
      updatePrompt()
    of kBackspace:
      if lineBuffer.len > 0:
        # Pop the last Rune (handles multi-byte UTF-8).
        var runes = lineBuffer.toRunes()
        runes.setLen(runes.len - 1)
        lineBuffer = $runes
      updatePrompt()
    else:
      discard  # ignore function keys, arrows, etc.

proc main() {.async: (raises: [CancelledError, Exception]).} =
  ## withInlineScreen owns all three teardown tiers:
  ##   tier-1 (finally): teardownFlush on normal return or exception.
  ##   tier-2 (graceful signal): watchTeardownSignals wakes on SIGTERM/INT,
  ##     calls teardownFlush in normal context, then restoreAllAndReraise.
  ##   tier-3 (crash): static tail buffer armed on the output fd; crash handler
  ##     emits last committed bytes async-signal-safely.
  ## No manual teardown plumbing needed.
  withInlineScreen(newTerminalSink(), 24, 80, 2, s):
    let stream = fi.newInputStream(cint(0))
    fi.start(stream)
    defer: fi.stop(stream)
    await app(stream, s)

waitFor main()
