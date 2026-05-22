## Single-dispatcher enforcement (#50).
##
## fresco assumes one chronos dispatcher per process. Some hazards
## (silent disk corruption in PersistentJournal) are too dangerous
## to leave to documentation alone, so the journal write sites
## call `assertDispatcherThread()` — process-global CAS that stamps
## the first calling thread and raises on cross-thread calls. The
## probe is injectable so tests can simulate multi-thread without
## requiring `--threads:on`.

import std/[os, unittest]
import intonaco/concurrency
import intonaco/journal/events
import intonaco/journal/log
import intonaco/journal/persist

suite "concurrency: assertDispatcherThread":

  teardown:
    resetDispatcherThread()
    dispatcherProbe = nil       # restore default for next test

  test "first call stamps the thread; same-thread re-call succeeds":
    var fakeThreadId = 100
    dispatcherProbe = proc(): int = fakeThreadId
    assertDispatcherThread()    # stamps 100
    assertDispatcherThread()    # same thread — no raise

  test "second call from a different thread raises":
    var observed = 100
    dispatcherProbe = proc(): int = observed
    assertDispatcherThread()      # stamps 100
    observed = 200                # simulate a different thread
    expect MultiDispatcherDefect:
      assertDispatcherThread()

  test "resetDispatcherThread clears the stamp":
    var observed = 100
    dispatcherProbe = proc(): int = observed
    assertDispatcherThread()      # stamps 100
    resetDispatcherThread()
    observed = 200
    # After reset, a new thread can stamp without raising.
    assertDispatcherThread()
    # And re-calling from that same new thread succeeds.
    assertDispatcherThread()

suite "concurrency: PersistentJournal enforces single-dispatcher":

  teardown:
    resetDispatcherThread()
    dispatcherProbe = nil

  test "onPersist (event write) from a foreign thread raises Defect":
    var observed = 100
    dispatcherProbe = proc(): int = observed
    let path = getTempDir() / ("fresco-conc-" & $getCurrentProcessId() & ".log")
    defer: discard tryRemoveFile(path)
    let j = openJournal(path)
    let t = TaskId.fresh()
    discard j.logSignalWrite(t, NoEvent, "x", "1")    # stamps 100
    observed = 200                                    # foreign thread
    expect MultiDispatcherDefect:
      discard j.logSignalWrite(t, NoEvent, "x", "2")
    close(j)

  test "compactBefore from a foreign thread raises Defect":
    var observed = 100
    dispatcherProbe = proc(): int = observed
    let path = getTempDir() / ("fresco-conc-c-" & $getCurrentProcessId() & ".log")
    defer: discard tryRemoveFile(path)
    let j = openJournal(path)
    let t = TaskId.fresh()
    discard j.logSignalWrite(t, NoEvent, "x", "1")    # stamps 100
    let cutId = j.events[^1].id
    observed = 200                                    # foreign thread
    expect MultiDispatcherDefect:
      j.compactBefore(cutId)
    close(j)

  test "addSnapshot from a foreign thread raises Defect (via onSnapshotAppended)":
    var observed = 100
    dispatcherProbe = proc(): int = observed
    let path = getTempDir() / ("fresco-conc-s-" & $getCurrentProcessId() & ".log")
    defer: discard tryRemoveFile(path)
    let j = openJournal(path)
    let t = TaskId.fresh()
    discard j.logSignalWrite(t, NoEvent, "x", "1")    # stamps 100
    observed = 200                                    # foreign thread
    expect MultiDispatcherDefect:
      discard j.addSnapshot()
    close(j)

  test "in-memory Journal (not Persistent) doesn't enforce — documented limit":
    var observed = 100
    dispatcherProbe = proc(): int = observed
    let j = newJournal()
    let t = TaskId.fresh()
    discard j.logSignalWrite(t, NoEvent, "x", "1")    # base no-op onPersist
    observed = 200
    # No stamp was taken (assertDispatcherThread isn't called from
    # the base Journal's onPersist) — writes from "another thread"
    # don't raise. This is the documented limit: in-memory misuse
    # produces inconsistent state but not silent disk corruption,
    # so we don't pay the runtime cost.
    discard j.logSignalWrite(t, NoEvent, "x", "2")
    check j.events.len == 2
