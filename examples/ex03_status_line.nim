## Pin a status row at the bottom while writing streamed output above.
##
## Visual check: the status row stays put through all 30 stderr writes;
## the streamed lines scroll within the region above it.

import std/strformat
import chronos
import fresco/screen
import fresco/widgets/status

proc main() {.async: (raises: [Exception]).} =
  let screen = newScreen(cint(2))
  let status = newStatus(screen, height = 1)
  defer: status.destroy()

  for i in 1 .. 30:
    status.set([fmt"streaming {i}/30"])
    screen.paint()
    stderr.writeLine fmt"output line {i}"
    await sleepAsync(120.milliseconds)

  status.set(["done."])
  screen.paint()

waitFor main()
