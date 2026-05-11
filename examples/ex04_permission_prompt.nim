## Replica of recall's permission-prompt UI: a select menu under a
## descriptive header. This is the first downstream use case fresco
## was built for.

import chronos
import fresco/input as fi
import fresco/screen
import fresco/widgets/select
import fresco/terminal/ansi

proc main() {.async: (raises: [CancelledError, Exception]).} =
  stderr.writeLine bold("Tool requests permission")
  stderr.writeLine "  command: " & color("rm -rf node_modules/", cYellow)
  stderr.writeLine "  cwd:     /home/you/projects/some-repo"
  stderr.writeLine ""

  let stream = newInputStream(cint(0))
  fi.start(stream)
  defer: fi.stop(stream)

  let screen = newScreen(cint(2))
  let height = min(5, screen.height)
  let region = newRegion(screen, row = 0, col = 0,
                         height = height, width = min(60, screen.width))

  let outcome = await selectMenu(stream, screen, region,
    @["allow once", "allow for session", "deny", "edit command"])

  stderr.write "\n"
  case outcome.kind
  of soChosen:
    case outcome.index
    of 0: stderr.writeLine "→ allowed once"
    of 1: stderr.writeLine "→ allowed for session"
    of 2: stderr.writeLine "→ denied"
    else: stderr.writeLine "→ edit (demo: not wired up)"
  of soCancelled:    stderr.writeLine "→ cancelled"
  of soSlashCommand: stderr.writeLine "→ slash: " & outcome.command

waitFor main()
