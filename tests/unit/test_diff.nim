import std/[unittest, sequtils, strutils]
import fresco/widgets/diff

suite "diffLines (LCS)":

  test "identical inputs are all keeps":
    let d = diffLines(@["a", "b", "c"], @["a", "b", "c"])
    check d.len == 3
    for op in d: check op.op == doKeep

  test "pure additions":
    let d = diffLines(@[], @["x", "y"])
    check d.mapIt(it.op) == @[doAdd, doAdd]
    check d.mapIt(it.text) == @["x", "y"]

  test "pure removals":
    let d = diffLines(@["x", "y"], @[])
    check d.mapIt(it.op) == @[doRemove, doRemove]

  test "edit in the middle preserves surrounding context":
    let d = diffLines(@["a", "b", "c"], @["a", "B", "c"])
    check d.mapIt(it.op) == @[doKeep, doRemove, doAdd, doKeep]
    check d[0].text == "a"
    check d[1].text == "b"
    check d[2].text == "B"
    check d[3].text == "c"

  test "insertion at end":
    let d = diffLines(@["a"], @["a", "b"])
    check d.mapIt(it.op) == @[doKeep, doAdd]

  test "deletion at start":
    let d = diffLines(@["a", "b"], @["b"])
    check d.mapIt(it.op) == @[doRemove, doKeep]

suite "renderUnified":

  test "prefix conventions":
    let d = diffLines(@["one", "two"], @["one", "TWO"])
    let r = renderUnified(d)
    check r.len == 3
    check r[0].startsWith(" ")     # keep
    check "-" in r[1] and "two" in r[1]
    check "+" in r[2] and "TWO" in r[2]
