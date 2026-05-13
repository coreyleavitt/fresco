## TaskGroup — bounded dynamic set of supervised tasks with shared
## lifecycle operations. Composes with Supervisor for restart-on-crash
## via `Supervisor.adopt(group, ...)`.
##
##   let group = newTaskGroup(maxSize = 16)
##   let mount = ?group.spawn(proc(): Future[void] {.async.} = work(arg))
##   await group.joinAll()
##   await group.cancelAll()
##
## TaskGroup is useful standalone (matches Rust tokio's `JoinSet`, Go's
## `errgroup`, Swift's `TaskGroup`). For automatic restart on failure,
## adopt it under a Supervisor — the supervisor uses the per-slot
## `ChildFactory` stored at spawn time to re-spawn.

import chronos
import results
import ./core

type
  GroupError* = enum
    geFull           ## member count would exceed `maxSize`
    geShuttingDown   ## `cancelAll` has been called (or supervisor unwinding)

  GroupSlot = object
    mount: Mount
    factory: ChildFactory

  SpawnHook* = proc(m: Mount, factory: ChildFactory) {.gcsafe, raises: [].}

  TaskGroup* = ref object
    maxSize*: int
    members: seq[GroupSlot]
    shuttingDown: bool
    spawnHook: SpawnHook

proc newTaskGroup*(maxSize: int): TaskGroup =
  ## Construct a TaskGroup. `maxSize` is the upper bound on concurrent
  ## members; further `spawn` calls return `geFull` until a member
  ## finishes (auto-removed on its future completion).
  doAssert maxSize > 0, "TaskGroup.maxSize must be > 0"
  TaskGroup(maxSize: maxSize)

proc size*(g: TaskGroup): int =
  ## Current live member count.
  g.members.len

proc members*(g: TaskGroup): seq[Mount] =
  ## Snapshot of currently-live members. The returned seq is owned by
  ## the caller — subsequent group operations don't mutate it.
  result = newSeqOfCap[Mount](g.members.len)
  for slot in g.members:
    result.add slot.mount

proc removeMount(g: TaskGroup, m: Mount) =
  for i in 0 ..< g.members.len:
    if g.members[i].mount == m:
      g.members.delete(i)
      return

proc joinAll*(g: TaskGroup) {.async: (raises: [CancelledError, CatchableError]).} =
  ## Await every live member to finish (complete, fail, or cancel).
  ## Snapshots the current member set; members spawned after the call
  ## starts are not awaited (use a sentinel pattern if you need that).
  ## Member exceptions are not re-raised here — callers inspect each
  ## Mount's future if they need per-member outcomes.
  var snap = newSeqOfCap[Mount](g.members.len)
  for slot in g.members:
    snap.add slot.mount
  for m in snap:
    try: await m.future
    except CancelledError: raise   # the AWAITER was cancelled
    except CatchableError: discard
  await sleepAsync(0.milliseconds)   # drain auto-remove callbacks

proc setSpawnHook*(g: TaskGroup, hook: SpawnHook) =
  ## Internal — set by `Supervisor.adopt` to register a callback that
  ## fires after every successful `spawn`. The hook receives the new
  ## Mount and its factory; the supervisor uses this to track
  ## per-member factories for restart and to wake its run-loop race.
  ## Single-set: calling twice raises Defect.
  doAssert g.spawnHook == nil, "TaskGroup spawn hook already set"
  g.spawnHook = hook

iterator slots*(g: TaskGroup): tuple[mount: Mount, factory: ChildFactory] =
  ## Internal — iterate live (mount, factory) pairs. Used by
  ## `Supervisor.adopt` to build the run-loop race set.
  for slot in g.members:
    yield (slot.mount, slot.factory)

proc cancelAll*(g: TaskGroup) {.async: (raises: [CancelledError]).} =
  ## Cancel every live member, await each to settle, mark the group
  ## as shutting down (refusing further `spawn` calls). Members swallow
  ## their own `CancelledError`; this call only re-raises if the
  ## awaiting task itself is cancelled.
  g.shuttingDown = true
  # Snapshot mounts before cancelling — auto-remove callbacks may
  # mutate `g.members` mid-iteration.
  var snap = newSeqOfCap[Mount](g.members.len)
  for slot in g.members:
    snap.add slot.mount
  for m in snap:
    if not m.future.finished: m.cancel()
  for m in snap:
    try: await m.future
    except CancelledError: discard
    except CatchableError: discard
  # Give the dispatcher one tick to drain auto-remove callbacks
  # registered on each member's future.
  await sleepAsync(0.milliseconds)

proc spawn*(g: TaskGroup, factory: ChildFactory): Result[Mount, GroupError] =
  ## Spawn a new member running `factory()`. Returns the Mount on
  ## success. Returns `geFull` when at capacity, `geShuttingDown`
  ## after `cancelAll` has been called.
  ##
  ## The member auto-removes from the group when its future finishes
  ## (complete/fail/cancel). The stored `factory` is used by an
  ## adopting Supervisor for restart-on-failure.
  if g.shuttingDown:
    return Result[Mount, GroupError].err(geShuttingDown)
  if g.members.len >= g.maxSize:
    return Result[Mount, GroupError].err(geFull)
  let m = spawn factory()
  g.members.add GroupSlot(mount: m, factory: factory)
  let groupRef = g
  let mountRef = m
  m.future.addCallback(proc(udata: pointer) {.gcsafe, raises: [].} =
    groupRef.removeMount(mountRef))
  if g.spawnHook != nil:
    g.spawnHook(m, factory)
  Result[Mount, GroupError].ok(m)
