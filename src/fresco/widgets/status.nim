## Status widget — a region pinned to the last `height` rows that
## doesn't get clobbered by streamed output above.
##
## The mechanism is DEC Set Top/Bottom Margins (DECSTBM): we install
## a scroll region covering rows 1..(screen.height - statusHeight),
## so when other code writes streamed output and the terminal scrolls,
## only those rows move — the status row stays put. The widget restores
## the default scroll region on `destroy`.

import std/posix
import ../screen
import ../terminal/ansi

type
  Status* = ref object
    region*: Region
    screen*: Screen
    height*: int

proc setScrollRegion*(top, bottom: int): string =
  ## DECSTBM. `top`/`bottom` are 1-based, inclusive.
  CSI & $top & ";" & $bottom & "r"

proc resetScrollRegion*(): string =
  ## Restore the default scroll region (full screen).
  CSI & "r"

proc emit(s: Screen, bytes: string) =
  if bytes.len > 0:
    discard posix.write(s.fd, unsafeAddr bytes[0], bytes.len)

proc newStatus*(screen: Screen, height: int = 1): Status =
  doAssert height >= 1 and height < screen.height,
    "status height must leave at least one row above"
  let region = newRegion(screen,
    row = screen.height - height,
    col = 0,
    height = height,
    width = screen.width)
  screen.emit(setScrollRegion(1, screen.height - height))
  Status(region: region, screen: screen, height: height)

proc set*(s: Status, lines: openArray[string]) =
  s.region.set(lines)

proc destroy*(s: Status) =
  s.screen.emit(resetScrollRegion())
