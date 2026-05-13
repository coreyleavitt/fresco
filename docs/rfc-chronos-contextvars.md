# RFC: Continuation-local storage for chronos

**Status**: Draft v2.1 (reconciled with as-built implementation)
**Author**: Corey Leavitt
**Targets**: github.com/status-im/nim-chronos

## Why v2.1

This document originally specified `AsyncCallback.context` as `pointer` with manual `GC_ref`/`GC_unref` paired with explicit `releaseCallbackContext` calls at every drop site. Code review against the implementation surfaced two real concerns with that design:

1. **The latent `sequtils.keepItIf` shallowCopy leak under `--mm:refc`** — `keepItIf`'s `shallowCopy` bypasses custom `=destroy`/`=copy`/`=sink` hooks, so any hook-based lifecycle scheme has a silent leak in `removeCallback`'s filter loop.
2. **Contributor-discipline failure modes** — every new scheduling site needed to remember the manual `GC_ref` / `GC_unref` pair. The two-constructor split (`userCallback`/`internalCallback`) made capture discipline structural, but lifetime discipline at drop sites remained by-convention.

v2.1 changes the field type from `pointer` (manual lifecycle) to `ref ContextNodeBase` (Nim's MM owns the lifecycle). The change touches one type declaration in `futures.nim` and deletes ~12 explicit `releaseCallbackContext` calls across the dispatcher; the rest of the RFC's surface (macro shape, two-constructor split, propagation semantics) is preserved.

## Why v2 (historical)

A prior draft of this RFC was paired with a prototype implementation that drifted from the design in two architecturally-significant places: tag identity (designed: `distinct void` generative phantom types; implemented: `addr {.global.}: int`) and value storage (designed: pointer + macro-inlined accessors; implemented: `RootRef` + `ContextBox[T]` heap wrapper). Both drifts compounded into real concerns: ABI fragility across dyn-link boundaries, double heap allocation per bind, `cast(gcsafe)` blocks on the dispatcher hot path, lost POD-ness of `AsyncCallback`, sentinel-as-template instead of `const`. v2 corrected these via slot-typed subtype storage. v2.1 (this document) closes the lifetime question.

## Summary

Add first-class continuation-local storage (CLS) to chronos. Bindings introduced inside an async task are visible to all code within that task — including across `await` suspensions — and don't leak to unrelated concurrent tasks. The design uses Nim's compile-time machinery to produce a runtime-keyed primitive that is faster, more type-safe, and less ABI-fragile than the Python-`contextvars`-by-direct-port shape that a naive implementation would produce.

User-facing API:

```nim
contextVar:
  var currentUser: User = anonymous
  var requestId: string = ""

proc handler() {.async.} =
  withCurrentUser(authedUser):
    let result = await db.query(...)
    audit(currentUser(), result)        # currentUser() == authedUser
```

## Motivation

Async runtimes need a way to propagate dynamically-scoped state through coroutine suspensions. Every modern async ecosystem has converged on this primitive:

| Runtime    | Primitive             |
| ---------- | --------------------- |
| Python     | `contextvars.ContextVar` (PEP 567) |
| .NET       | `AsyncLocal<T>` + `ExecutionContext` |
| Kotlin     | `CoroutineContext`    |
| Rust tokio | `task_local!`         |
| Node.js    | `AsyncLocalStorage`   |
| Scheme     | `parameterize` / parameters |

Common use cases:

- **Request-scoped data**: a web server attaches "current user," "request ID," "trace span" to a request; all async work spawned during that request inherits the context. Concurrent requests don't interfere.
- **Structured-concurrency owners**: a parent task installs an "owner" or "scope" reference; child operations propagate it through `await` for cleanup attribution.
- **Logging / tracing**: each async task carries its trace context; structured logs are correlatable without explicit-parameter threading.
- **Speculative / transactional state**: a task opens an optimistic-write frame; mutations within the task see the frame across awaits, mutations in sibling tasks don't.

Without runtime-level support, applications must hand-roll save/restore around every await — either via per-proc macro rewriting (fragile, doesn't compose with template-emitted awaits) or by threading context through every function signature (verbose, error-prone, breaks library boundaries).

Chronos currently provides no primitive for this. fresco — a Nim terminal-UI kernel — previously carried a ~150-line CLS substrate workaround (`{.task.}` pragma macro + `taskAwait` helper); this RFC's eventual adoption collapses that to a handful of `contextVar` declarations. fresco is the first reference downstream consumer.

## Design goals

1. **Continuation-scoped, not thread-scoped.** A binding follows the logical task across suspensions.
2. **Tasks inherit at spawn; mutations don't leak back.** Concurrent tasks can't interfere unless they explicitly share context.
3. **Type-safe.** Reading a context binding returns the declared value type without `cast` or `Option` unwrapping in the common case.
4. **Zero-overhead-when-unused.** Async procs that don't touch CLS pay near-zero runtime cost: one nil-ref field write at construction (`context: currentAsyncContext` with `currentAsyncContext == nil`), no heap allocation, no refcount op. `AsyncCallback`'s `context` is a native `ref` — Nim's MM (refc/orc/arc) does the refcount when there *is* a binding. The dispatcher hot path stays allocation-free.
5. **Idiomatic Nim.** Single-form declaration; uniform call syntax (`name()`, not `name.get()`); compile-time type identity (not runtime object identity).
6. **Collision-resistant by construction.** Two libraries declaring identically-named context vars don't silently interfere — type system distinguishes them.
7. **Capture coverage is structural, not by-convention.** A type-system-enforced split between user-facing and internal callback construction makes it impossible to add a new user-facing scheduling API without thinking about context capture.
8. **Public/private split.** Dispatcher-internal primitives live in `chronos/internal/`; only the user-facing surface (`contextVar` macro + `withContext` template) is public.

## API specification

### Declaration

```nim
contextVar:
  var currentUser: User = anonymous
  var requestId: string = ""
```

A pragma-style macro that declares one or more context variables in a block. Generates:
- A unique slot type (`ref object of ContextNodeBase` with a `value: T` field — fresh per declaration; the type system guarantees collision detection because two declarations with the same name produce types with the same name)
- A typed reader `name()` returning `T`
- A scoped binder `withName(v): body` that introduces a binding for the dynamic extent of `body`

Generated code (sketch, per arm):

```nim
type CurrentUserSlot = ref object of ContextNodeBase
  value: User

template currentUser*(): User =
  contextLookup[CurrentUserSlot, User](anonymous)

template withCurrentUser*(v: User, body: untyped) =
  contextBindSlot[CurrentUserSlot, User](v, body)
```

Single-line form is also accepted: `contextVar var currentUser: User = anonymous` (no block).

### Reading

```nim
let value = name()
```

The declared name is callable. Returns the current binding for the calling task, or the declared default if no binding is in scope. Always typed `T`; never raises.

### Scoped binding

```nim
withName(v):
  body
```

Generated alongside the declaration. Binds `v` to `name` for the dynamic extent of `body`, including across any `await` within. On exit (normal, exception, cancellation), the binding reverts.

### Context capture/restore for callback-style code

```nim
let captured: AsyncContext = currentContext()
# ... time passes, dispatcher runs other tasks ...
withContext(captured):
  body
```

For callback-style code that fires from the dispatcher with whatever context happens to be current and wants to restore the context that was current at registration. Async procs awaiting futures don't need this — propagation is automatic.

### Complete user-facing API surface

Only these symbols are exported from `chronos/contextvars`:

```nim
macro contextVar*(body: untyped): untyped

type AsyncContext* = distinct ContextNodeBase  # opaque snapshot (ref semantics so it keeps the chain alive past the binder)
proc currentContext*(): AsyncContext
template withContext*(ctx: AsyncContext, body: untyped)
```

That's the entire public surface. No `ContextVar[T]` runtime object. No `set` / `reset` / `Token`. No `copy_context` / `Context.run`. No `ContextNode`, no `contextGet`/`contextBind`, no `setCurrentContext` — those are internal.

## Semantics

### The context

Every async task has an associated *context*: a stack of `(tag, value)` bindings keyed by compile-time tag-type identity. Reading walks the stack from innermost outward, returning the first match (or the default if absent).

### Propagation

Two propagation events:

1. **At task spawn.** When an async proc is called and produces a Future, the new task inherits the caller's current context. Subsequent `withName` introductions are local to the new task.

2. **At suspend/resume.** When a user-facing scheduling primitive registers a callback, the dispatcher captures the current context. When the awaited Future completes (or the scheduled callback fires), the dispatcher restores that context before resuming. This is the load-bearing mechanism — it's why bindings survive `await`.

### Concurrent isolation

Because each task has its own context stack, two concurrent tasks that don't explicitly share context can't interfere. Task A's `withCurrentUser(alice): ...` is invisible to task B running on the same dispatcher.

### Cancellation

A task that is cancelled while inside a `withName(v)` block unwinds normally — Nim's `try/finally` semantics restore the prior binding on exception propagation. `CancelledError` is just an exception from the binding's perspective.

### Inherit-by-snapshot-at-suspend

A task that calls a child task synchronously (via direct call) shares the same context until the child suspends. After suspension, the child has its own captured context (the caller's context at the suspension's callback registration). Mutations to the child's context chain (via nested `withContext` blocks) don't propagate back to the caller — they're scoped to the child's `withName` body.

This matches Python contextvars and .NET ExecutionContext semantics.

## Implementation

### Tag identity AND value storage: distinct ref-object subtypes per declaration

Each `contextVar` arm emits a distinct `ref object` subtype of a shared `ContextNodeBase`. The value lives **inside the node** (`value: T` field), not at the address of a stack local. The "tag" is the type itself — the dispatcher's lookup uses Nim's runtime type test (`of`).

```nim
contextVar:
  var currentUser: User = anonymous
# expands to (in module scope):
type CurrentUserSlot = ref object of ContextNodeBase
  value: User
template currentUser*(): User =
  contextLookup[CurrentUserSlot, User](anonymous)
template withCurrentUser*(v: User, body: untyped) =
  contextBindSlot[CurrentUserSlot, User](v, body)
```

The chain is a linked list of `ContextNodeBase`:

```nim
type ContextNodeBase* = ref object of RootObj
  next: ContextNodeBase
```

Each declaration extends it with a `value: T` field. The walker uses `of` to find the matching node:

```nim
proc contextLookup[N: ContextNodeBase, T](default: T): T {.gcsafe, raises: [].} =
  var node = currentAsyncContext
  while node != nil:
    if node of N:
      return N(node).value
    node = node.next
  default
```

**This simultaneously addresses three concerns**:

1. **Tag identity is link-stable and type-system-driven.** No compile-time counter (which is per-module-instantiation in Nim and could collide across modules in incremental compilation). No `addr {.global.}: int` (which is per-loaded-copy under dynamic linking). The type identity is what Nim's type system carries — there is no separate runtime tag.

2. **Cross-module collision detection is structural.** Two modules each declaring `var currentUser: User = anonymous` each emit a type named `CurrentUserSlot`. If both are simultaneously in scope (e.g., consumed by a third module that imports both), Nim's type-checker fails with a name-collision error rather than silently sharing an integer tag. The "compile-time collision detection" property the design promises is provided by the type system, not by hand-rolled tag bookkeeping.

3. **Snapshot via `currentContext()` is sound for any T.** The value is owned by the node (`N(node).value`). A snapshot that outlives the original binder keeps the chain alive via Nim's normal refcounting; reading the value returns a copy (for value types) or the shared reference (for ref types). No stack-local addresses involved, so no use-after-free for value-typed bindings.

**Why not `distinct void` tag types + pointer-to-stack-local value storage** (the v2 first-implementation drift): the v2 RFC originally specified this, but a code-review pass revealed two structural defects:
- A compile-time int counter (the actual implementation that v2 settled into) is per-module-instantiation in Nim, so two modules' identically-named contextVars could silently share a tag id under incremental compilation or order-dependent module compilation. The "compile-time collision detection" claim was false.
- Storing `valueRef` as `addr` of a stack local in the `withName(v): body` template's expansion is sound only as long as the node is popped before the local's frame returns. `currentContext()` deliberately captures the chain past the binder's exit — read-through-snapshot then dereferences freed stack memory for value-typed bindings.

**Why not `RootRef` + `ContextBox[T]` heap wrapper** (the v1 drift): two heap allocations per bind (`ContextBox[T]` + the chain node) and unsound `ContextBox[T](r)` downcast (`ObjectConversionDefect` is theoretically possible). The current design has one heap allocation per bind — the slot itself — with the value owned inline; type recovery via `of` is the Nim runtime's checked type test.

**Per-bind cost**: one `Slot` allocation. Value is owned by the slot, no boxing layer. Reads walk the chain doing one `of` check per node until matched.

### Dispatcher integration

`InternalAsyncCallback` gains a native `ref` field:

```nim
type InternalAsyncCallback* = object
  function*: CallbackFunc
  udata*: pointer
  context*: ContextNodeBase   # native ref; nil if no bindings
```

Lifetime is delegated to Nim's MM: every refc / arc / orc maintains the refcount automatically across assignment overwrite, seq element removal, future GC'd with pending callbacks, deque popFirst, `.reset()`, and container teardown. No manual `GC_ref` / `GC_unref` — they were error-prone (every new scheduling site needed to remember them) and inherited the latent `sequtils.keepItIf` shallowCopy bug under `--mm:refc`.

`ContextNodeBase` is declared in `chronos/futures.nim` (alongside `InternalAsyncCallback`) so the field can be typed directly — declaring it in `internal/contextvars_impl.nim` (which imports `futures.nim`) would close a circular dependency.

`SentinelCallback` is a no-arg `template` (not `const` or `let`):
- `const X = AsyncCallback(...)` — Nim 2.x rejects `const` of an object containing a `ref` field, even when the ref is nil.
- `let X = AsyncCallback(...)` — a module-level `let` containing a `ref` field is gcsafe-inaccessible from dispatcher procs like `poll`.
- The template emits a fresh rvalue at every call site with `context: nil`. No global GC'd state to read, gcsafe-clean. `isSentinel` keeps full struct-equality (`acb == SentinelCallback()`); nil-ref comparison is pointer equality so the check stays cheap.

The dispatcher's `processCallbacks` loop:

```nim
template processCallbacks(loop: untyped) =
  while true:
    let callable = loop.callbacks.popFirst()
    if isSentinel(callable):
      break
    if not(isNil(callable.function)):
      let chronosCtxPrev = currentAsyncContext
      currentAsyncContext = callable.context
      try:
        callable.function(callable.udata)
      finally:
        currentAsyncContext = chronosCtxPrev
```

No `cast[ContextNodeBase]` (the field already has the right type), no `{.cast(gcsafe).}` wrapper (ref-typed reads from threadvars are gcsafe). When the loop iteration drops `callable`, Nim's MM releases the captured chain.

### Capture discipline: two-constructor split

The reason v1's review caught 10+ user-facing scheduling sites missing context capture is that capture was *by-convention* — every `AsyncCallback(function: ..., udata: ...)` literal had to remember `context: currentAsyncContext`. v2 makes the responsibility structural via two named constructors:

```nim
# In chronos/internal/contextvars_impl.nim:
proc userCallback*(fn: CallbackFunc, udata: pointer = nil): AsyncCallback {.inline, raises: [].} =
  ## Construct an AsyncCallback that fires user-supplied code. Captures
  ## the current continuation-local context at construction so the
  ## callback fires under the same contextVar bindings the registrant
  ## had at registration. Use this for every add*/callSoon-like site
  ## that schedules user code.
  AsyncCallback(function: fn, udata: udata, context: currentAsyncContext)

template internalCallback*(fn: CallbackFunc, ud: pointer = nil): AsyncCallback =
  ## Construct an AsyncCallback that fires chronos-internal scaffolding
  ## (IOCP completion handlers, idle-loop sentinels, fd-readiness
  ## trampolines that just complete user futures). No context capture —
  ## the chronos-internal code being scheduled doesn't read contextVars,
  ## and the user-visible callbacks downstream (the awaiters on whatever
  ## future the trampoline completes) already carry their own captured
  ## context via their original `addCallback`.
  ##
  ## Template (not proc) so it can appear in template-form rvalues —
  ## chiefly `SentinelCallback` and other dispatcher-internal sites.
  AsyncCallback(function: fn, udata: ud, context: nil)
```

The raw `AsyncCallback(function: ..., udata: ...)` literal is internal-private. Every scheduling site uses one of the two named constructors. Adding a new `add*` API forces the author to pick — the wrong choice is loud rather than silent.

Site coverage:
- `userCallback`: `addCallback` (both branches), `callSoon(cb, data)`, `setTimer`, `cancelSoon`'s aftercb, `addReader2`/`addWriter2`, `addSignal2`/`addProcess2`, `callIdle`, `internalCallTick`, `closeSocket(fd, aftercb)`, `closeHandle(fd, aftercb)`
- `internalCallback`: IOCP completion repackaging (line 658), aftercb close hooks where they're chronos-internal trampolines, `SentinelCallback`, idle-loop dispatch internals
- A CI grep test verifies the raw `AsyncCallback(function:` literal appears ONLY in the two constructor definitions themselves; any drift triggers test failure.

### Module split

```
chronos/
├── futures.nim                      # ContextNodeBase type declaration (alongside InternalAsyncCallback's
│                                    #   `context: ContextNodeBase` field — co-located to break circular import)
├── contextvars.nim                  # PUBLIC: contextVar macro, AsyncContext, currentContext, withContext
├── internal/
│   └── contextvars_impl.nim         # INTERNAL: currentAsyncContext threadvar,
│                                    #   contextLookup / contextBindSlot generic helpers,
│                                    #   userCallback / internalCallback constructors,
│                                    #   chainLen / contextNodeBalance (debug-only test hooks)
```

`chronos.nim` re-exports `contextvars`. The dispatcher code in `internal/asyncfutures.nim` + `internal/asyncengine.nim` imports `internal/contextvars_impl` for the primitives. Users see only the public surface; chronos's API stability guarantee scopes only what's in `chronos/contextvars.nim`.

`ContextNodeBase` lives in `futures.nim` (not in `contextvars_impl.nim`) because `InternalAsyncCallback.context: ContextNodeBase` is a typed field — declaring the type in `contextvars_impl.nim` (which imports `futures.nim`) would close a circular dependency. The type is short (3 lines) and has no operations attached, so the placement is mechanical.

### Spawn-time inheritance

When an async proc is called for the first time, its initial run inherits the caller's context naturally (the caller's threadvar is current; the iterator runs synchronously). When the iterator yields a future, `futureContinue` wraps the body in save/restore (line 399 of asyncfutures.nim) so the iterator's context bindings don't leak to the caller's threadvar. The capture of the iterator's context happens at the `addCallback` inside `futureContinue` (line 418): `next.addCallback(CallbackFunc(internalContinue), cast[pointer](fut))` routes through `userCallback`, capturing the iterator's `currentAsyncContext` at suspension. On resume, `processCallbacks` restores that captured context before invoking `internalContinue`, so the iterator resumes under the same bindings it had at the yield point.

This is the one deliberate exception to the two-constructor split's "internal trampolines use `internalCallback`" rule. `internalContinue` is technically an internal trampoline, but the capture is load-bearing here — it's what carries the iterator's per-yield context across suspension. Other internal trampolines (`internalCallTick`'s `CallbackFunc` overloads, `idleAsync`'s completion stub, IOCP completion repackaging) correctly use `internalCallback`.

### Cancellation callback

`cancelCallback=` stores a bare `CallbackFunc`, not an `AsyncCallback`. Cancellation handlers run with the canceller's current context (not the cancellee's), because they fire synchronously inside the canceller's `cancel()` call. Document as "cancellation handlers see the canceller's context, not the future's originator's context."

## Migration / compatibility

**Zero breaking changes to existing chronos APIs.** All current chronos consumers work unchanged. CLS is opt-in via `contextVar` declarations. Async procs that never declare or read a context var pay nothing — `AsyncCallback.context` is `nil`, the dispatcher's restore is two pointer writes that branch-predict trivially.

**Cooperation with `multisync`**: synchronous variants don't have a dispatcher and can't propagate context. Reading a context var from a `multisync`'d sync body returns the default. Document.

**Thread interaction**: chronos's dispatcher is single-thread-per-loop. Each dispatcher has its own current-context (threadvar). Threads don't share context. CLS is per-dispatcher.

**Windows IOCP — `addProcess2` / `addSignal2` propagation gap (known limitation)**: On Linux (epoll) and macOS/BSD (kqueue), `addProcess2` and `addSignal2` use `userCallback` correctly and the user callback fires under the registrant's context. On Windows, both APIs route through `registerWaitable` which stores `cb` as a bare `CallbackFunc` in `CompletionData` (no context captured at registration), then wraps it via `internalCallback` at the IOCP completion site (no context restored at fire time). Result: user callbacks scheduled via these two APIs on Windows see whatever context the dispatcher last set, not the registration-time context. This is a pre-existing structural issue in the Windows IOCP path that the contextvars RFC inherits; fixing it requires adding a `context: ContextNodeBase` field to `CompletionData` and threading capture/restore through `registerWaitable`. Deferred until a Windows CI environment is available to verify. TODO comment marked in `asyncengine.nim` at the completion site.

## Benchmark plan

The dispatcher gains: one ref-field write at capture (in `userCallback`, with Nim's MM emitting `nimIncRef` only when the captured context is non-nil), two ref-field writes at fire (save/restore around `cb.function(cb.udata)`), one ContextNode allocation per `withName` (heap), and one auto-decref at iteration-end (Nim's MM emits `nimGCunref` when `callable` drops out of `processCallbacks`'s loop scope).

To validate no regression on chronos's hot path:

1. **Tight-loop callback throughput**: 1M iterations of `callSoon`-fire-`callSoon`-fire with no context bindings. Compare against unpatched chronos. Acceptable: <2% regression.
2. **`sleepAsync` throughput**: 10K sleep(1.microseconds) cycles. Compare. Acceptable: <2%.
3. **Transport read throughput**: streaming reader over localhost socket pair. Compare. Acceptable: <5% (we touch addReader which now captures context).
4. **`withName` cost**: 100K bind-read-unbind cycles. Document baseline; this is a new operation so we measure absolute, not regression.
5. **Concurrent isolation under load**: 100 concurrent tasks each binding different contextVars, all sharing the dispatcher, each verifying its binding survives N suspensions. Functional test; failure indicates context leak.

Benchmarks land alongside the implementation; PR body includes results.

## Test plan

**Unit / sync:**
- Default value when no binding in scope
- Scoped binding visible inside body, reverts on exit
- Nested bindings see innermost, restore correctly  
- Exception in body still reverts
- Different value types bind independently
- Repeated binding of the same var

**Async / integration:**
- Binding survives single await
- Binding survives multiple sequential awaits
- **Real concurrent isolation**: two tasks with interleaved suspensions, each verifies its own binding after each yield. v1's test was sequential (taskA fully completed before taskB's check); v2 must actually interleave.
- Child task inherits parent's context at spawn
- Child's nested binding doesn't leak back to parent
- Exception across await reverts binding
- Multiple value types coexist on same context chain
- **Cancellation across `withName` body**: `withCurrentUser(authed): try: await work() except CancelledError: check currentUser() == authed`
- **`addReader` inside `withName`**: fresco's actual use case — register an fd-readiness callback inside a binding, fire it, verify the callback sees the binding.
- **`callSoon` / `callIdle` / `internalCallTick` direct binding**: each user-facing scheduler captures correctly.
- **`closeSocket(fd, aftercb)` / `closeHandle(fd, aftercb)`**: aftercb fires with registration-time context.
- **`race()` and `allFutures()`**: combinators propagate context to their continuations.

**Binder contract (MM-portable, no GC-timing dependency):**
- `chainLen()` — direct walk of `currentAsyncContext`. After every balanced `withName` body the chain depth must return to baseline. Verified for normal exit, exception exit, and nested binders.
- `contextNodeBalance` — debug-only threadvar incremented at slot push / decremented at slot pop in `contextBindSlot`. Suite-end check in `testutils.nim` (alongside `pendingFuturesCount`) catches any binder that pushed without popping.

These replace finalizer-based leak probes that proved unreliable under `--mm:refc` (deferred finalizer dispatch). The native-ref design means per-drop refcount correctness is a Nim MM guarantee, not a chronos invariant; the binder-contract tests verify what chronos itself is responsible for.

**Macro hygiene:**
- `contextVar` accepts `nnkIdent`, `nnkPostfix`, AND `nnkSym` in arm names — required for composition from wrapper macros that build the name via `genSym` or process typed AST. The macro normalizes incoming names through `ident($name)` before emission so an `nskVar`-flavored symbol can still be used as a template name.

**Meta:**
- CI grep test: raw `AsyncCallback(function:` literal appears only in `chronos/internal/contextvars_impl.nim`. Any drift fails the test.
- Static assertion: `InternalAsyncCallback.context is ContextNodeBase` — catches any regression to manual `pointer` lifecycle.

## Alternatives considered

### A. Python-style runtime `ContextVar[T]` object

```nim
let currentUser = newContextVar[User](anonymous)
currentUser.set(authedUser)
let u = currentUser.get()
```

Requires per-declaration heap allocation; uses object identity as the dispatcher's lookup key. Loses Nim's compile-time collision detection (`ContextVar('user_id')` and `ContextVar('user_id')` in different modules silently coexist as different runtime objects). The current design preserves the user-facing ergonomics (declaration → reader → binder) while eliminating the runtime object via compile-time type identity.

### B. `addr {.global.}: int` for tag identity (v1's drift)

Generate `var nameContextTag {.global.}: int` per declaration; use `addr nameContextTag` as runtime tag. Functionally equivalent for the single-binary case, but globals are not guaranteed link-stable across shared-library boundaries (each loaded copy gets its own address), and the runtime-keyed lookup misses the compile-time-collision-detection win that motivates the type-keyed design.

### C. `RootRef` + `ContextBox[T]` wrapper (v1's drift)

Store erased values as `RootRef` pointing at a `ContextBox[T]` heap allocation. Two heap allocations per bind, unsound downcast (`ContextBox[T](r)` is a runtime-checked conversion that can theoretically raise `ObjectConversionDefect` despite the macro's invariant guaranteeing match). The slot-typed subtype design (one heap allocation per bind, value owned inline, `of`-based recovery using Nim's runtime type test) produces strictly less work and stronger type safety.

### D. Imperative `set` / `reset` / `Token` API

Python contextvars exposes this in addition to scoped binding. Every legitimate use case is covered by `withName`; tokens add API surface and invite the binding-without-reset anti-pattern. Omitted from MVP. If a real consumer needs it, can be added without disturbing the rest of the design.

### E. `Context.run(ctx, callable)` for explicit context switching

Covered by `withContext(ctx, body)` (the snapshot/restore form). The public surface includes `currentContext()` + `withContext(ctx, body)` as the canonical "capture + run" pair.

### F. Effect-system enforcement of capture

A typed-pass macro walks call graphs and verifies that every user-facing scheduling primitive captures context. More mechanical enforcement than the two-constructor split, but requires effect-system extensions to Nim that don't otherwise exist. Two-constructor split + CI grep test is sufficient and doesn't add language-level machinery.

### G. Capture context at every AsyncCallback construction site

The "blanket capture" approach: rather than splitting into user/internal constructors, capture at every site. Avoids the contributor-discipline question. Rejected because:
- IOCP completion repackaging (asyncengine.nim:658) doesn't need user context — capturing whatever-the-dispatcher-leaked context would be semantically wrong (the captured value has no meaning).
- The split makes the *intent* of each site explicit. "Why are we capturing here?" becomes "because `userCallback` says we are." The blanket approach hides the intent.

### H. `context: pointer` with manual `GC_ref` / `GC_unref` (this RFC's original design)

`AsyncCallback.context` as a raw `pointer` field; `userCallback` does `GC_ref(currentAsyncContext)` at construction; explicit `releaseCallbackContext(cb)` calls at every drop site (`clearTimer`, `removeTimer`, `removeReader2`, `processCallbacks`-after-fire, `clearCallbacks`, `removeCallback`, etc.). Preserved `AsyncCallback`'s POD-ness and let `SentinelCallback` stay a `const`.

Rejected after implementation review because:
- **Latent leak under `--mm:refc`**: `sequtils.keepItIf` uses `shallowCopy` which bypasses custom `=destroy`/`=copy`/`=sink` hooks. `removeCallback`'s filter loop would silently leak the context ref of any callback past the first matching element.
- **Contributor-discipline failure mode**: every new scheduling site needed to remember `GC_ref` at construction AND every new drop site needed to remember `releaseCallbackContext`. Capture had the two-constructor split for structural enforcement; release had no such structural enforcement.
- **Reinventing `ref`**: properly maintaining the refcount across copies (deque slots, struct overwrites, container teardowns) requires defining `=destroy` + `=copy` + `=sink` hooks — at which point we've reinvented exactly what Nim's `ref` already does, paying per-copy hook dispatch instead of compiler-emitted incref/decref ops.

The native `ref` design (chosen) inherits a language-level guarantee instead of asserting a chronos-level invariant; the failure modes above all become impossible.

## Risks and open questions

1. **Persistent-map upgrade timing.** MVP uses a singly-linked stack of `ContextNode`s. For users with deep nesting (10+ bindings in a deep stack), this becomes O(n) per read. Upgrading to a HAMT or similar structure-shared persistent map is mechanical (API doesn't change). Defer until profiling justifies it.
2. **Naming.** `contextVar` is the proposed name; `asyncLocal` (matches .NET prior art + chronos's `Async*` convention) is an alternative. Open question for chronos maintainers.
3. **Cancellation-callback context** documented above (canceller's context, not cancellee's). Confirm with chronos maintainers; if they prefer cancellee's, the storage of `cancelCallback=` needs to change to `AsyncCallback`.
4. **Closure iterator `yield` inside `withName`**: Nim's closure iterators preserve try/finally state across yields, so the binding restore on body exit fires correctly even after suspension. Covered by `binding survives multiple sequential awaits` and related tests.
5. **Cycle risk via user-bound ref values.** `context: ContextNodeBase` is a native ref; if a user binds a value containing a `ref` back into something that holds the binding's owning future (rare but possible in pathological code), the cycle would leak under ARC but be reclaimed under ORC's cycle collector. Same property every other Nim `ref` field carries — not novel to this RFC. Chronos's existing position on refc/orc support governs.
6. **Multi-thread embedders.** The threadvar `currentAsyncContext` is per-thread; chronos is single-thread-per-dispatcher. Multiple dispatchers running on multiple threads each have their own context chain. This is consistent with chronos's existing design and the v2 RFC's stated single-dispatcher-per-thread invariant.

## Prior art and references

- Python contextvars (PEP 567): https://peps.python.org/pep-0567/
- .NET AsyncLocal\<T\> + ExecutionContext: https://learn.microsoft.com/en-us/dotnet/api/system.threading.asynclocal-1
- Kotlin CoroutineContext: https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlinx.coroutines/-coroutine-context/
- Rust tokio task_local!: https://docs.rs/tokio/latest/tokio/macro.task_local.html
- Node.js AsyncLocalStorage: https://nodejs.org/api/async_context.html
- Scheme parameterize / Racket parameters: https://docs.racket-lang.org/reference/parameters.html

## Reference implementation

The reference implementation lives at `github.com/coreyleavitt/chronos` in the `feat/contextvars` branch. Status:
- v1 (manual tag id + RootRef box) wiped after code review.
- v2 (slot-typed subtypes + `context: pointer` with manual `GC_ref`/`releaseCallbackContext`) implemented, then superseded by v2.1 after the latent-leak / contributor-discipline analysis.
- v2.1 (current — native `ref` field, no manual lifecycle) implemented, 506 tests passing under `--mm:refc -d:chronosDebug -d:useSysAssert -d:useGcAssert`. ORC matrix run gated on Nim > 1.6 (chronos.nimble:67) — runs after refc passes.

The downstream consumer is `fresco` — a Nim terminal-UI kernel — which migrated its CLS-using code to the user-facing surface (`contextVar` declarations + `withName` templates + `withContext` snapshot/restore). The migration is the integration test for the design; the surface this RFC specifies has been preserved across v1 → v2 → v2.1 reimplementations.

---

*Comments, objections, design alternatives, and acceptance-blocking concerns are welcomed before code review begins.*
