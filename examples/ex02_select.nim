## Render a select menu over the top 5 rows; print the outcome.
##
## Visual check: arrows / j-k navigate, numbers 1..N jump, Enter picks,
## Ctrl-C and Esc cancel, `/` enters slash mode for a typed command.

import chronos
import fresco/input as fi
import fresco/screen
import fresco/widgets/select

proc main() {.async: (raises: [CancelledError, Exception]).} =
  let stream = newInputStream(cint(0))
  fi.start(stream)
  defer: fi.stop(stream)

  let screen = newScreen(cint(2))
  let region = newRegion(screen, row = 0, col = 0,
                         height = 5, width = min(40, screen.width))

  let outcome = await selectMenu(stream, screen, region,
    @["read a file", "edit a file", "run a command", "do nothing"])

  stderr.write "\n"
  case outcome.kind
  of soChosen:
    stderr.writeLine "chose: " & $outcome.index
  of soCancelled:
    stderr.writeLine "cancelled"
  of soSlashCommand:
    stderr.writeLine "slash: " & outcome.command

waitFor main()
