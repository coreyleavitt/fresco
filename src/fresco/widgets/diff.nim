## Line-level diff widget.
##
## v0 algorithm: classic Hunt-McIlroy LCS table (O(m*n) memory). Good
## enough for tool-output diffs up to a few thousand lines; real
## file-edit review usage in recall will be bounded well below that.
## Myers / patience can replace it later if needed.

import std/[algorithm, sequtils, strutils]
import ../screen
import ../terminal/ansi

type
  DiffOp* = enum
    doKeep
    doAdd
    doRemove

  DiffLine* = object
    op*: DiffOp
    text*: string

  DiffMode* = enum
    dmUnified
    dmSideBySide

# --- LCS-based diff -------------------------------------------------------

proc lcsTable(a, b: openArray[string]): seq[seq[int]] =
  result = newSeqWith(a.len + 1, newSeq[int](b.len + 1))
  for i in 1 .. a.len:
    for j in 1 .. b.len:
      result[i][j] =
        if a[i - 1] == b[j - 1]: result[i - 1][j - 1] + 1
        else: max(result[i - 1][j], result[i][j - 1])

proc diffLines*(a, b: openArray[string]): seq[DiffLine] =
  ## Return the ordered list of keep/add/remove operations that turn
  ## `a` into `b`. Result length is at least max(a.len, b.len).
  let t = lcsTable(a, b)
  var i = a.len
  var j = b.len
  while i > 0 or j > 0:
    if i > 0 and j > 0 and a[i - 1] == b[j - 1]:
      result.add DiffLine(op: doKeep, text: a[i - 1])
      dec i; dec j
    elif j > 0 and (i == 0 or t[i][j - 1] >= t[i - 1][j]):
      result.add DiffLine(op: doAdd, text: b[j - 1])
      dec j
    else:
      result.add DiffLine(op: doRemove, text: a[i - 1])
      dec i
  result.reverse()

# --- Rendering ------------------------------------------------------------

proc renderUnified*(diff: seq[DiffLine]): seq[string] =
  result = @[]
  for d in diff:
    case d.op
    of doKeep:   result.add " "  & d.text
    of doAdd:    result.add color("+", cGreen) & " " & color(d.text, cGreen)
    of doRemove: result.add color("-", cRed)   & " " & color(d.text, cRed)

proc renderSideBySide*(diff: seq[DiffLine], colWidth: int): seq[string] =
  ## Pair each op as (leftCell, rightCell). Keep → both sides identical;
  ## Add → empty left, Remove → empty right. Lines longer than colWidth
  ## are truncated with an ellipsis sigil so the layout stays clean.
  proc cell(text: string): string =
    if text.len <= colWidth: text & spaces(colWidth - text.len)
    else: text[0 ..< colWidth - 1] & "…"
  result = @[]
  for d in diff:
    case d.op
    of doKeep:
      result.add cell(d.text) & " │ " & cell(d.text)
    of doRemove:
      result.add color(cell(d.text), cRed) & " │ " & cell("")
    of doAdd:
      result.add cell("") & " │ " & color(cell(d.text), cGreen)

# --- Widget ---------------------------------------------------------------

type
  Diff* = ref object
    region*: Region
    mode*: DiffMode
    rows*: seq[string]

proc toLines(s: string): seq[string] =
  if s.len == 0: @[] else: strutils.splitLines(s)

proc newDiff*(region: Region, oldText, newText: string,
              mode = dmUnified): Diff =
  let ops = diffLines(toLines(oldText), toLines(newText))
  let rendered =
    case mode
    of dmUnified: renderUnified(ops)
    of dmSideBySide:
      let col = max(1, (region.width - 3) div 2)
      renderSideBySide(ops, col)
  Diff(region: region, mode: mode, rows: rendered)

proc render*(d: Diff) =
  ## Clip the rendered rows to the region's height and set the target.
  ## v0: no internal scrolling — wrap the region in a Scrollback if
  ## you need that.
  var window = newSeq[string](d.region.height)
  for i in 0 ..< d.region.height:
    window[i] = if i < d.rows.len: d.rows[i] else: ""
  d.region.set(window)
