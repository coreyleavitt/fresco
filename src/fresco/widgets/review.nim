## Review widget — prompt + diff + approve/reject/edit composite.
##
## Layout:
##
##   ┌── prompt ───────────────┐  1 row
##   │ Heading / description   │
##   ├── diff region ──────────┤  flex
##   │ - old line              │
##   │ + new line              │
##   │ ...                     │
##   ├── actions ──────────────┤  3 rows: select menu
##   │ > approve               │
##   │   reject                │
##   │   edit feedback         │
##   └─────────────────────────┘
##
## "edit feedback" replaces the actions region with a single-line
## input prompt; submitting that returns `rkEditFeedback` with the
## typed text.

import chronos
import ../input
import ../screen
import ../layout
import ./diff
import ./select
import ./input as inputw

type
  ReviewOutcomeKind* = enum
    rkApprove
    rkReject
    rkEditFeedback
    rkCancelled

  ReviewOutcome* = object
    case kind*: ReviewOutcomeKind
    of rkEditFeedback: feedback*: string
    else: discard

const ReviewActions* = @["approve", "reject", "edit feedback"]

proc review*(stream: InputStream,
             screen: Screen,
             top, left, height, width: int,
             prompt: string,
             oldText, newText: string,
             mode = dmUnified
            ): Future[ReviewOutcome]
            {.async: (raises: [CancelledError, Exception]).} =
  doAssert height >= 6, "review widget needs at least 6 rows"

  # Stack: 1 row prompt, flex diff, 3 rows actions.
  let promptH = 1
  let actionsH = 3
  let diffH = height - promptH - actionsH

  let v = newVStack(screen, weights = [promptH, diffH, actionsH],
                    top = top, left = left,
                    height = height, width = width)
  let promptR  = v.regions[0]
  let diffR    = v.regions[1]
  let actionsR = v.regions[2]

  promptR.set([prompt])
  let d = newDiff(diffR, oldText, newText, mode = mode)
  d.render()
  screen.paint()

  let pick = await selectMenu(stream, screen, actionsR, ReviewActions)
  case pick.kind
  of soCancelled:
    return ReviewOutcome(kind: rkCancelled)
  of soSlashCommand:
    # Slash-command from inside review is not in v0 scope; fold to
    # cancelled so the caller gets a clean outcome.
    return ReviewOutcome(kind: rkCancelled)
  of soChosen:
    case pick.index
    of 0: return ReviewOutcome(kind: rkApprove)
    of 1: return ReviewOutcome(kind: rkReject)
    of 2:
      # Reuse the actions region as an input prompt.
      let outcome = await inputLine(stream, screen, actionsR,
                                    prompt = "feedback> ")
      case outcome.kind
      of ioSubmitted:
        return ReviewOutcome(kind: rkEditFeedback,
                             feedback: outcome.text)
      of ioCancelled:
        return ReviewOutcome(kind: rkCancelled)
    else:
      return ReviewOutcome(kind: rkCancelled)
