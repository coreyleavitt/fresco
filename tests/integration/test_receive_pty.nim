## Drive the `receive` macro through a real PTY pair.

import std/unittest
import std/[posix, termios, unicode]
import chronos
import fresco/input as fresco_input
import fresco/events
import fresco/receive
import intonaco/task/mailbox

import intonaco/reactive/scope
import intonaco/journal/log

proc posix_openpt(flags: cint): cint {.importc, header: "<stdlib.h>".}
proc grantpt(fd: cint): cint           {.importc, header: "<stdlib.h>".}
proc unlockpt(fd: cint): cint          {.importc, header: "<stdlib.h>".}
proc ptsname(fd: cint): cstring        {.importc, header: "<stdlib.h>".}

proc openPtyPair(): tuple[master, slave: cint] =
  let master = posix_openpt(O_RDWR or O_NOCTTY)
  doAssert master >= 0
  doAssert grantpt(master) == 0
  doAssert unlockpt(master) == 0
  let slave = open(ptsname(master), O_RDWR or O_NOCTTY)
  doAssert slave >= 0
  return (master, slave)

proc writeAll(fd: cint, s: string) =
  if s.len == 0: return
  let n = posix.write(fd, unsafeAddr s[0], s.len)
  doAssert n == s.len

template rig(keys: string, body: untyped): string =
  ## Drive one receive arm: open PTY, write `keys` to master, then run
  ## the receive `body`, which writes into the injected `outcome`
  ## string. Returns `outcome`.
  block:
    proc inner(): Future[string] {.async: (raises: [Exception]).} =
      let (master, slave) = openPtyPair()
      let stream {.inject.} = newInputStream(slave)
      fresco_input.start(stream)
      defer:
        fresco_input.stop(stream)
        discard close(master)
        discard close(slave)

      var outcome {.inject.} = ""
      proc feeder() {.async: (raises: [Exception]).} =
        await sleepAsync(20.milliseconds)
        writeAll(master, keys)
      asyncSpawn feeder()
      body
      return outcome

    waitFor inner()

suite "receive: unified (arm grammar inside on)":

  test "tracer: arm pattern inside on block matches Char('a')":
    let got = rig("a"):
      receive:
        on stream as ev:
          Char('a'): outcome = "a"
          _:         outcome = "other"
    check got == "a"

  test "Char(c) capture binds the rune inside an on block":
    let got = rig("Q"):
      receive:
        on stream as ev:
          Char(c): outcome = "char:" & $c
          _:       outcome = "other"
    check got == "char:Q"

  test "wildcard `_:` inside an on block catches non-enumerated keys":
    let got = rig("z"):
      receive:
        on stream as ev:
          Char('a'): outcome = "a"
          _:         outcome = "fallback"
    check got == "fallback"

  test "modifier-prefix Shift(Tab) inside on block matches CSI Z":
    let got = rig("\x1b[Z"):
      receive:
        on stream as ev:
          Tab:        outcome = "tab"
          Shift(Tab): outcome = "shift-tab"
          _:          outcome = "other"
    check got == "shift-tab"

  test "after Duration alongside arm-shaped on body":
    proc inner(): Future[string] {.async: (raises: [Exception]).} =
      let (master, slave) = openPtyPair()
      let stream = newInputStream(slave)
      fresco_input.start(stream)
      defer:
        fresco_input.stop(stream)
        discard close(master); discard close(slave)
      var outcome = "unset"
      receive:
        on stream as ev:
          Char(c): outcome = "char:" & $c
          _:       outcome = "other"
        after 50.milliseconds:
          outcome = "timeout"
      return outcome
    check waitFor(inner()) == "timeout"

  test "two sources: one arm-bodied (stream), one free-bodied (mailbox)":
    proc inner(): Future[string] {.async: (raises: [Exception]).} =
      let (master, slave) = openPtyPair()
      let stream = newInputStream(slave)
      fresco_input.start(stream)
      defer:
        fresco_input.stop(stream)
        discard close(master); discard close(slave)
      let mbox = newMailbox[int]()
      mbox.push(42)               # mailbox has an event ready
      var outcome = "unset"
      receive:
        on stream as ev:
          Char(c): outcome = "char:" & $c
          _:       outcome = "stream-other"
        on mbox as m:
          outcome = "mbox:" & $m
      return outcome
    check waitFor(inner()) == "mbox:42"

  test "mixed arm-shaped + free statements in same on body fails to compile":
    # The macro requires each `on` body to be either ALL arms or ALL
    # free statements. A mixed body is ambiguous and must be flagged.
    let m = newMailbox[KeyEvent]()
    check not compiles(
      block:
        proc bad() {.async: (raises: [Exception]).} =
          receive:
            on m as ev:
              Char('a'): discard
              discard 42                # free statement after an arm
        waitFor bad()
    )

  test "per-on wildcard scope: each on block's _ only applies inside its block":
    # The wildcard inside `on stream as ev:` does NOT catch events
    # that came from `mbox`. Only the mbox-arm runs when mbox fires.
    proc inner(): Future[string] {.async: (raises: [Exception]).} =
      let (master, slave) = openPtyPair()
      let stream = newInputStream(slave)
      fresco_input.start(stream)
      defer:
        fresco_input.stop(stream)
        discard close(master); discard close(slave)
      let mbox = newMailbox[int]()
      mbox.push(99)
      var outcome = "unset"
      receive:
        on stream as ev:
          Char(c): outcome = "stream:" & $c
          _:       outcome = "stream-other"
        on mbox as m:
          outcome = "mbox:" & $m
      return outcome
    check waitFor(inner()) == "mbox:99"

suite "receive: core patterns":

  test "Char literal pattern matches":
    let got = rig("+"):
      receive:
        on stream as ev:
          Char('+'): outcome = "plus"
          Char('-'): outcome = "minus"
          _:         outcome = "other"
    check got == "plus"

  test "Char capture binds the rune":
    let got = rig("Q"):
      receive:
        on stream as ev:
          Char(c): outcome = "char:" & $c
          _:       outcome = "other"
    check got == "char:Q"

  test "Ctrl literal pattern matches":
    let got = rig("\x03"):
      receive:
        on stream as ev:
          Ctrl('c'): outcome = "quit"
          _:         outcome = "other"
    check got == "quit"

  test "Ctrl capture binds the letter":
    let got = rig("\x17"):
      receive:
        on stream as ev:
          Ctrl(c): outcome = "ctrl:" & $c
          _:       outcome = "other"
    check got == "ctrl:w"

  test "Alt capture binds the letter":
    let got = rig("\x1ba"):
      receive:
        on stream as ev:
          Alt(c): outcome = "alt:" & $c
          _:      outcome = "other"
    check got == "alt:a"

  test "Enter atom pattern matches":
    let got = rig("\r"):
      receive:
        on stream as ev:
          Enter: outcome = "submit"
          _:     outcome = "other"
    check got == "submit"

  test "Backspace atom":
    let got = rig("\x7F"):
      receive:
        on stream as ev:
          Backspace: outcome = "bs"
          _:         outcome = "other"
    check got == "bs"

  test "Arrow atoms":
    let got = rig("\x1b[A"):
      receive:
        on stream as ev:
          ArrowUp:    outcome = "up"
          ArrowDown:  outcome = "down"
          ArrowLeft:  outcome = "left"
          ArrowRight: outcome = "right"
          _:          outcome = "other"
    check got == "up"

  test "F-key atom":
    let got = rig("\x1bOP"):
      receive:
        on stream as ev:
          F1:        outcome = "help"
          F12:       outcome = "save"
          _:         outcome = "other"
    check got == "help"

  test "Shift(Tab) modifier-prefix arm matches CSI Z (#67)":
    let got = rig("\x1b[Z"):
      receive:
        on stream as ev:
          Tab:         outcome = "tab"
          Shift(Tab):  outcome = "shift-tab"
          _:           outcome = "other"
    check got == "shift-tab"

  test "Ctrl(ArrowUp) modifier-prefix arm matches \\e[1;5A":
    let got = rig("\x1b[1;5A"):
      receive:
        on stream as ev:
          ArrowUp:        outcome = "up"
          Ctrl(ArrowUp):  outcome = "ctrl-up"
          _:              outcome = "other"
    check got == "ctrl-up"

  test "Ctrl(Shift(End)) nested modifier prefix matches \\e[1;6F":
    let got = rig("\x1b[1;6F"):
      receive:
        on stream as ev:
          End:                 outcome = "end"
          Shift(End):          outcome = "shift-end"
          Ctrl(Shift(End)):    outcome = "ctrl-shift-end"
          _:                   outcome = "other"
    check got == "ctrl-shift-end"

  test "bare atom arm doesn't match a modified key (modifier sets differ)":
    # `Tab:` matches kTab with empty modifier set. Shift+Tab has
    # modShift; it should fall through to the wildcard.
    let got = rig("\x1b[Z"):
      receive:
        on stream as ev:
          Tab:  outcome = "tab"
          _:    outcome = "other"
    check got == "other"

  test "wildcard catches everything not enumerated":
    let got = rig("z"):
      receive:
        on stream as ev:
          Char('a'): outcome = "a"
          Char('b'): outcome = "b"
          _:         outcome = "other"
    check got == "other"

  test "no wildcard, no matching arm: silently drops, outcome unset":
    let got = rig("z"):
      receive:
        on stream as ev:
          Char('a'): outcome = "a"
          Enter:     outcome = "enter"
    check got == ""

  test "wildcard at end of body catches non-enumerated keys":
    # Regression: previous implementation pulled the wildcard out of
    # source order and put it as the final `else`, which meant arms
    # *after* a wildcard would fire BEFORE the wildcard. Now arms
    # after `_:` are warned as unreachable; arms before fire in order.
    let got = rig("z"):
      receive:
        on stream as ev:
          Char('a'): outcome = "a"
          Char('b'): outcome = "b"
          _:         outcome = "fallback"
    check got == "fallback"

    let got2 = rig("a"):
      receive:
        on stream as ev:
          Char('a'): outcome = "a"
          Char('b'): outcome = "b"
          _:         outcome = "fallback"
    check got2 == "a"

  test "specific Char before general Char(c) priorities by source order":
    let got = rig("a"):
      receive:
        on stream as ev:
          Char('a'): outcome = "literal-a"
          Char(c):   outcome = "fallback-" & $c
    check got == "literal-a"

    let got2 = rig("b"):
      receive:
        on stream as ev:
          Char('a'): outcome = "literal-a"
          Char(c):   outcome = "fallback-" & $c
    check got2 == "fallback-b"

suite "receive: after timeout":

  test "after fires when no key arrives in time":
    proc inner(): Future[string] {.async: (raises: [Exception]).} =
      let (master, slave) = openPtyPair()
      let stream = newInputStream(slave)
      fresco_input.start(stream)
      defer:
        fresco_input.stop(stream)
        discard close(master); discard close(slave)
      var outcome = "unset"
      receive:
        on stream as ev:
          Char(c): outcome = "char:" & $c
        after 50.milliseconds: outcome = "timeout"
      return outcome
    check waitFor(inner()) == "timeout"

  test "key arm wins when input precedes the timeout":
    let got = rig("z"):
      receive:
        on stream as ev:
          Char(c):                 outcome = "char:" & $c
        after 500.milliseconds:    outcome = "timeout"
    check got == "char:z"

  test "after-only receive compiles and times out cleanly":
    # Regression: a receive with only an `after:` arm used to produce
    # an empty nnkIfStmt (invalid AST) — the macro now skips the chain
    # entirely when nonAfterArms is empty.
    proc inner(): Future[string] {.async: (raises: [Exception]).} =
      let (master, slave) = openPtyPair()
      let stream = newInputStream(slave)
      fresco_input.start(stream)
      defer:
        fresco_input.stop(stream)
        discard close(master); discard close(slave)
      var outcome = "unset"
      receive:
        after 30.milliseconds: outcome = "tick"
      return outcome
    check waitFor(inner()) == "tick"

  test "after-only receive discards key on the key-arrival path":
    let got = rig("x"):
      receive:
        on stream as ev:
          _: discard
        after 200.milliseconds: outcome = "timeout"
      if outcome == "":
        outcome = "key-discarded"
    check got == "key-discarded"

  test "await inside a receive arm body is CLS-protected by {.task.}":
    # Verify the AST-walking analysis: the task macro's rewriter
    # descends into the receive call's argument stmtlist (since macro
    # args are just AST when task runs), so user-source-level awaits
    # inside arm bodies ARE rewritten with save/restore. A signal
    # write after such an await attributes to the task's scope, not
    # to whichever stale scope the dispatcher left in currentScope.
    proc inner(): Future[bool] {.async: (raises: [Exception]).} =
      resetJournal()
      discard useJournal()
      let (master, slave) = openPtyPair()
      let stream = newInputStream(slave)
      fresco_input.start(stream)
      defer:
        fresco_input.stop(stream)
        discard close(master); discard close(slave)
      writeAll(master, "x")
      let taskScopeBefore = currentScope
      receive:
        on stream as ev:
          Char(c):
            await sleepAsync(2.milliseconds)
            # After await inside arm body: currentScope must still be
            # the {.task.}'d outer scope.
            return currentScope == taskScopeBefore
          _: return false
      return false
    check waitFor(inner())

  test "stream close mid-wait propagates rather than firing after":
    # Regression for round-3 C1: receive's after-clause used to fall
    # into the timer branch when keyFut.failed (e.g. stream closed),
    # silently treating the closure as a timeout.
    proc inner(): Future[string] {.async: (raises: [Exception]).} =
      let (master, slave) = openPtyPair()
      let stream = newInputStream(slave)
      fresco_input.start(stream)
      defer:
        discard close(master); discard close(slave)
      var outcome = "unset"
      proc closer() {.async: (raises: [Exception]).} =
        await sleepAsync(20.milliseconds)
        fresco_input.stop(stream)
      asyncSpawn closer()
      try:
        receive:
          on stream as ev:
            Char(c):                 outcome = "char:" & $c
          after 500.milliseconds:    outcome = "timeout"
      except InputStreamClosedError:
        outcome = "closed"
      return outcome
    check waitFor(inner()) == "closed"
