## Verify that `import fresco` brings in the user-facing surface.

{.experimental: "callOperator".}

import std/[unittest, unicode]
import fresco

suite "aggregate import":

  test "core types exported":
    check Region is type
    check Screen is type
    check KeyEvent is type
    check InputStream is type
    check Signal[int] is type
    check Mount is type
    check Supervisor is type
    check Journal is type
    check Event is type
    check TaskId is type
    check EventId is type

  test "core constructors exported":
    discard signalC(0)
    discard newScreen(5, 10)
    discard charKey(Rune('x'))
    discard atomKey(kEnter)
    discard ctrlKey('c')
    discard newSupervisor()
    discard newJournal()

  test "DSL exports compile":
    signals:
      count = 0
    count := 1
    check count() == 1
