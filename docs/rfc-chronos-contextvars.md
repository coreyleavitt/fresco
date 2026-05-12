# RFC: Continuation-local storage for chronos

**Status**: Draft v2 (pre-PR design document — supersedes draft v1)
**Author**: Corey Leavitt
**Targets**: github.com/status-im/nim-chronos

## Why v2

A prior draft of this RFC was paired with a prototype implementation that drifted from the design in two architecturally-significant places: tag identity (designed: `distinct void` generative phantom types; implemented: `addr {.global.}: int`) and value storage (designed: pointer + macro-inlined accessors; implemented: `RootRef` + `ContextBox[T]` heap wrapper). Both drifts compounded into real concerns: ABI fragility across dyn-link boundaries, double heap allocation per bind, `cast(gcsafe)` blocks on the dispatcher hot path, lost POD-ness of `AsyncCallback`, sentinel-as-template instead of `const`.

This v2 RFC is the design we are building. The prototype branch has been wiped; the implementation will follow this document precisely.

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
4. **Zero-overhead-when-unused.** Async procs that don't touch CLS pay near-zero runtime cost. `AsyncCallback` retains POD-ness so the dispatcher's hot path stays allocation-free.
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
- A unique compile-time tag type (`distinct void` — fresh per declaration; the type system guarantees collision detection at compile time)
- A typed reader `name()` returning `T`
- A scoped binder `withName(v): body` that introduces a binding for the dynamic extent of `body`

Generated code (sketch, per arm):

```nim
type CurrentUserTag = distinct void

template currentUser*(): User =
  contextGetByTag(CurrentUserTag, User, anonymous)

template withCurrentUser*(v: User, body: untyped) =
  contextBindByTag(CurrentUserTag, User, v, body)
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

type AsyncContext* = object                  # opaque snapshot
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

### Tag identity: `distinct void` per declaration

The `contextVar` macro generates a unique tag type per arm:

```nim
contextVar:
  var currentUser: User = anonymous
# expands to:
type CurrentUserTag = distinct void
template currentUser*(): User = contextGetByTag(CurrentUserTag, User, anonymous)
template withCurrentUser*(v: User, body: untyped) =
  contextBindByTag(CurrentUserTag, User, v, body)
```

Each `distinct void` declaration produces a fresh type. The dispatcher's lookup uses the type's compile-time identity (via `getTypeId(T)` or equivalent — implementation detail of `contextGetByTag`/`contextBindByTag`).

**Why not `addr {.global.}: int`** (the v1 drift): global-address identity is fragile across dynamic-library boundaries (each loaded copy gets a distinct address; two consumers of the same library wrapping the same `contextVar` could end up with different keys for the same binding) and theoretically vulnerable to link-time deduplication. Compile-time type identity is link-stable and ABI-stable by construction.

**Why not a runtime `ContextVar` object** (the Python design): a runtime object with identity-based keying requires per-declaration allocation and indirect lookup. Nim's type system carries the identity natively — no allocation, no indirection, no runtime object to construct or store.

### Value storage: pointer + macro-inlined accessors

`ContextNode` stores values as `pointer`, not as `ref` or `RootRef`. The macro-generated accessors `currentUser()` and `withCurrentUser(v, body)` know `T` at compile time and emit the cast inline.

```nim
type ContextNode = ref object
  tag: pointer            # type-tag identity (typeId of the declaration's tag type)
  valueRef: pointer       # erased value pointer; reader casts back to T
  next: ContextNode
```

Binding pushes a node with `cast[pointer](addr boundLocal)` (or similar — depending on whether `T` is value-typed or ref-typed; implementation may need a small inline buffer for value-typed bindings to avoid stack-escape). Reading walks the chain, finds the matching tag, casts back to `T`.

**Why not `RootRef` + `ContextBox[T]` wrapper** (the v1 drift): double heap allocation per bind (one for `ContextBox[T]`, one for `ContextNode`). Unsound type recovery (`ContextBox[T](r)` is a runtime-checked downcast that theoretically can raise `ObjectConversionDefect`). `RootRef` indirection contributes nothing the macro-emitted inline cast doesn't already provide more directly.

**Per-bind cost**: one `ContextNode` allocation. For value-typed `T` that fits in a pointer, the value lives in `valueRef` directly (cast-based). For value-typed `T` larger than a pointer, the value lives in a stack-local that the `withName` template captures by `addr` for the dynamic extent of its body (Nim's `try/finally` lifetime guarantee makes this safe). For ref-typed `T`, the ref is stored in `valueRef` via `cast[pointer]`.

### Dispatcher integration

`InternalAsyncCallback` gains a `context: pointer` field (NOT `ref`):

```nim
type InternalAsyncCallback* = object
  function*: CallbackFunc
  udata*: pointer
  context*: pointer       # cast[pointer](ContextNode); nil if no bindings
```

Storing as `pointer` keeps `AsyncCallback` POD: no refcount ops at construction, `SentinelCallback` returns to `const` (it was `const` pre-RFC; v1 drift had to demote it to a template), no `cast(gcsafe)` blocks on the dispatcher hot path. Lifetime management of the referenced `ContextNode` follows the existing `GC_ref(fut)` pattern in `internalContinue`: when a callback is scheduled, the context is `GC_ref`'d; when fired, `GC_unref`'d after the call.

### Capture discipline: two-constructor split

The reason v1's review caught 10+ user-facing scheduling sites missing context capture is that capture was *by-convention* — every `AsyncCallback(function: ..., udata: ...)` literal had to remember `context: currentAsyncContext`. v2 makes the responsibility structural via two named constructors:

```nim
# In chronos/internal/contextvars_impl.nim:
proc userCallback*(fn: CallbackFunc, udata: pointer = nil): AsyncCallback {.inline.} =
  ## Construct an AsyncCallback that fires user-supplied code. Captures
  ## the current continuation-local context at construction time so the
  ## callback fires under the same contextVar bindings the registrant
  ## had at registration. Use this for every add*/callSoon-like site
  ## that schedules user code to run.
  AsyncCallback(function: fn, udata: udata,
                context: cast[pointer](currentAsyncContext))

proc internalCallback*(fn: CallbackFunc, udata: pointer = nil): AsyncCallback {.inline.} =
  ## Construct an AsyncCallback that fires chronos-internal scaffolding
  ## (IOCP completion handlers, idle-loop sentinels, fd-readiness
  ## trampolines that just complete user futures). No context capture —
  ## the chronos-internal code being scheduled doesn't read contextVars,
  ## and the user-visible callbacks downstream (the awaiters on whatever
  ## future the trampoline completes) already carry their own captured
  ## context via addCallback.
  AsyncCallback(function: fn, udata: udata, context: nil)
```

The raw `AsyncCallback(function: ..., udata: ...)` literal is internal-private. Every scheduling site uses one of the two named constructors. Adding a new `add*` API forces the author to pick — the wrong choice is loud rather than silent.

Site coverage:
- `userCallback`: `addCallback` (both branches), `callSoon(cb, data)`, `setTimer`, `cancelSoon`'s aftercb, `addReader2`/`addWriter2`, `addSignal2`/`addProcess2`, `callIdle`, `internalCallTick`, `closeSocket(fd, aftercb)`, `closeHandle(fd, aftercb)`
- `internalCallback`: IOCP completion repackaging (line 658), aftercb close hooks where they're chronos-internal trampolines, `SentinelCallback`, idle-loop dispatch internals
- A CI grep test verifies the raw `AsyncCallback(function:` literal appears ONLY in the two constructor definitions themselves; any drift triggers test failure.

### Module split

```
chronos/
├── contextvars.nim                  # PUBLIC: contextVar macro, AsyncContext, currentContext, withContext
├── internal/
│   └── contextvars_impl.nim         # PRIVATE: ContextNode, currentAsyncContext threadvar,
│                                    #   contextGetByTag/contextBindByTag, userCallback/internalCallback,
│                                    #   setCurrentContext, GC_ref/unref helpers
```

`chronos.nim` re-exports `contextvars`. The dispatcher code in `internal/asyncfutures.nim` + `internal/asyncengine.nim` imports `internal/contextvars_impl` for the primitives. Users see only the public surface; chronos's API stability guarantee scopes only what's in `chronos/contextvars.nim`.

### Spawn-time inheritance

When an async proc is called for the first time, its initial run inherits the caller's context naturally (the caller's threadvar is current; the iterator runs synchronously). When the iterator yields a future, `futureContinue` wraps the yield in save/restore so the iterator's context bindings don't leak to the caller's threadvar. The capture happens at the `addCallback` inside `futureContinue` (line 399 of asyncfutures.nim).

### Cancellation callback

`cancelCallback=` stores a bare `CallbackFunc`, not an `AsyncCallback`. Cancellation handlers run with the canceller's current context (not the cancellee's), because they fire synchronously inside the canceller's `cancel()` call. Document as "cancellation handlers see the canceller's context, not the future's originator's context."

## Migration / compatibility

**Zero breaking changes to existing chronos APIs.** All current chronos consumers work unchanged. CLS is opt-in via `contextVar` declarations. Async procs that never declare or read a context var pay nothing — `AsyncCallback.context` is `nil`, the dispatcher's restore is two pointer writes that branch-predict trivially.

**Cooperation with `multisync`**: synchronous variants don't have a dispatcher and can't propagate context. Reading a context var from a `multisync`'d sync body returns the default. Document.

**Thread interaction**: chronos's dispatcher is single-thread-per-loop. Each dispatcher has its own current-context (threadvar). Threads don't share context. CLS is per-dispatcher.

## Benchmark plan

The dispatcher gains: one pointer write at capture (in `userCallback`), two pointer writes at fire (save/restore around `cb.function(cb.udata)`), one ContextNode allocation per `withName` (heap), and one GC_ref/unref pair per scheduled-with-context callback.

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

**Meta:**
- CI grep test: raw `AsyncCallback(function:` literal appears only in `chronos/internal/contextvars_impl.nim`. Any drift fails the test.

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

Store erased values as `RootRef` pointing at a `ContextBox[T]` heap allocation. Two heap allocations per bind, unsound downcast (`ContextBox[T](r)` is a runtime-checked conversion that can theoretically raise `ObjectConversionDefect` despite the macro's invariant guaranteeing match). The pointer + macro-inlined cast in this design produces strictly less work and stronger type safety.

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

## Risks and open questions

1. **Persistent-map upgrade timing.** MVP uses a singly-linked stack of `ContextNode`s. For users with deep nesting (10+ bindings in a deep stack), this becomes O(n) per read. Upgrading to a HAMT or similar structure-shared persistent map is mechanical (API doesn't change). Defer until profiling justifies it.
2. **Naming.** `contextVar` is the proposed name; `asyncLocal` (matches .NET prior art + chronos's `Async*` convention) is an alternative. Open question for chronos maintainers.
3. **`getTypeId` portability.** The implementation relies on a stable per-type compile-time identifier. `system.hash(getType(T))` or equivalent — verify across Nim 1.6 / 2.0 / devel.
4. **Cancellation-callback context** documented above (canceller's context, not cancellee's). Confirm with chronos maintainers; if they prefer cancellee's, the storage of `cancelCallback=` needs to change to `AsyncCallback`.
5. **Closure iterator `yield` inside `withName`**: Nim's closure iterators preserve try/finally state across yields, so the binding restore on body exit fires correctly even after suspension. Explicit test for this in the test plan.

## Prior art and references

- Python contextvars (PEP 567): https://peps.python.org/pep-0567/
- .NET AsyncLocal\<T\> + ExecutionContext: https://learn.microsoft.com/en-us/dotnet/api/system.threading.asynclocal-1
- Kotlin CoroutineContext: https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlinx.coroutines/-coroutine-context/
- Rust tokio task_local!: https://docs.rs/tokio/latest/tokio/macro.task_local.html
- Node.js AsyncLocalStorage: https://nodejs.org/api/async_context.html
- Scheme parameterize / Racket parameters: https://docs.racket-lang.org/reference/parameters.html

## Reference implementation

The reference implementation will live at `github.com/coreyleavitt/chronos` in the `feat/contextvars` branch. The prior v1 branch was wiped (it drifted from this design); v2 is being built fresh against this RFC.

The downstream consumer is `fresco` — a Nim terminal-UI kernel — which has already migrated its CLS-using code to the user-facing surface (`contextVar` declarations + `withName` templates + `withContext` snapshot/restore). The migration is the integration test for the design; the surface this RFC specifies is preserved across the v1→v2 reimplementation.

---

*Comments, objections, design alternatives, and acceptance-blocking concerns are welcomed before code review begins.*
