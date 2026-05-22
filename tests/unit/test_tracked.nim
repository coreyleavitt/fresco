## Static dep-graph inference via `trackedEffect:` (#56).
##
## A typed-AST macro that wraps an effect body, statically extracts
## the set of labeled signals it reads, and registers the (effect,
## deps) pair so devtools / other consumers can query the dep graph
## without runtime instrumentation.

import std/[tables, unittest]
import intonaco/reactive/scope
import intonaco/reactive/signal
import intonaco/reactive/tracked

suite "trackedEffect: static dep extraction":

  test "single labeled-signal read registers the label":
    let n = signal(0, label = "n")
    var observed = -1
    discard createRoot:
      let eff = trackedEffect:
        observed = n()
      check effectDeps(eff) == @["n"]
    check observed == 0

  test "multiple labeled signals — both labels registered":
    let title = signal("hi", label = "title")
    let count = signal(0, label = "count")
    discard createRoot:
      let eff = trackedEffect:
        discard title()
        discard count()
      let deps = effectDeps(eff)
      check "title" in deps
      check "count" in deps
      check deps.len == 2

  test "unlabeled signal contributes nothing":
    let unlabeled = signal(42)            # no label kwarg
    let labeled = signal(0, label = "k")
    discard createRoot:
      let eff = trackedEffect:
        discard unlabeled()
        discard labeled()
      check effectDeps(eff) == @["k"]

  test "conditional read — over-reports (both branches in static set)":
    # Static analysis can't tell which branch will run; the dep
    # set is the union of every signal syntactically referenced.
    # Documented trade-off vs dynamic tracking.
    let a = signal(0, label = "a")
    let b = signal(0, label = "b")
    let cond = signal(true, label = "cond")
    discard createRoot:
      let eff = trackedEffect:
        if cond():
          discard a()
        else:
          discard b()
      let deps = effectDeps(eff)
      check "a" in deps
      check "b" in deps
      check "cond" in deps

  test "body with no signal reads — empty dep set":
    discard createRoot:
      let eff = trackedEffect:
        var x = 0
        for i in 1 .. 5: x += i
        discard x
      check effectDeps(eff).len == 0

  test "multiple trackedEffect blocks register independently":
    let a = signal(0, label = "a")
    let b = signal(0, label = "b")
    discard createRoot:
      let eff1 = trackedEffect:
        discard a()
      let eff2 = trackedEffect:
        discard b()
      check effectDeps(eff1) == @["a"]
      check effectDeps(eff2) == @["b"]

  test "same signal read twice — deduped":
    let s = signal(0, label = "s")
    discard createRoot:
      let eff = trackedEffect:
        discard s()
        discard s()
        discard s()
      check effectDeps(eff) == @["s"]
