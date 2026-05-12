# RFC: Continuation-local storage for chronos

**Status**: Draft (pre-PR design document)
**Author**: Corey Leavitt
**Targets**: github.com/status-im/nim-chronos

## Summary

Add first-class continuation-local storage (CLS) to chronos. Bindings introduced inside an async task are visible to all code within that task — including across `await` suspensions — and don't leak to unrelated concurrent tasks. The proposed API uses a Nim-native generative-phantom-type implementation under a Python-`contextvars`-shaped surface, eliminating the runtime `ContextVar` object that other ecosystems carry.

User-facing API:

```nim
contextVar currentUser: User = anonymous       # one-line declaration

proc handler() {.async.} =
  withCurrentUser(authedUser):                 # scoped binding
    let result = await db.query(...)           # currentUser() returns authedUser
    audit(currentUser(), result)               # ...even after the await
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

Chronos currently provides no primitive for this. Applications wanting CLS-like behavior must:

1. Reinvent it (macro-rewriter substrate that wraps every `await`), or
2. Avoid threadvar-based state across awaits, or
3. Pass context explicitly through every function signature

All three have failure modes the runtime could eliminate.

## Design goals

1. **Continuation-scoped, not thread-scoped.** A binding follows the logical task across suspensions, regardless of which OS thread runs which dispatcher iteration.
2. **Tasks inherit at spawn; mutations don't leak back.** Concurrent tasks can't interfere unless they explicitly share context.
3. **Type-safe.** Reading a context binding returns the declared value type without `cast` or `Option` unwrapping in the common case.
4. **Zero-overhead-when-unused.** Async procs that don't touch CLS pay near-zero runtime cost (one pointer per `AsyncCallback`; one nil check per callback fire).
5. **Idiomatic Nim.** Single-form declaration; uniform call syntax (`name()`, not `name.get()`); compile-time enforcement where the type system allows it.
6. **Collision-resistant by construction.** Two libraries declaring identically-named context vars don't silently interfere.

## API specification

### Declaration

```nim
contextVar name: T = default
```

A pragma-style macro that declares a context variable. Generates accessors, the underlying type tag, and the default-value registration. One line, total.

### Reading

```nim
let value = name()
```

The declared name is callable. Returns the current binding for the calling task, or the declared default if no binding is in scope. Always typed `T`; never raises in the default-provided form.

### Scoped binding

```nim
withName(v):
  body
```

Generated alongside the declaration. Binds `v` to `name` for the dynamic extent of `body`, including across any `await` within. On exit (normal, exception, or cancellation), the binding reverts.

### Generic handle-form (optional)

```nim
withContext(name, v):
  body
```

Equivalent to `withName(v): body`. Available when code receives a context-var handle as a generic argument (rare; documented for completeness).

### Complete API surface

```nim
# Declaration macro:
macro contextVar*(decl: untyped): untyped
  ## `contextVar name: T = default` — declares a context var.
  ## Generates a unique compile-time tag type, the reader `name()`,
  ## and the scoped binder `withName(v): body`.

# Reading (generated per declaration):
template `name`*(): T

# Binding (generated per declaration):
template `withName`*(v: T, body: untyped)

# Generic binding (always available):
template withContext*[Tag, T](tag: typedesc[Tag], v: T, body: untyped)
```

That's the entire public surface. No `ContextVar[T]` runtime object. No `set` / `reset` / `Token`. No `copy_context` / `Context.run`.

## Semantics

### The context

Every async task has an associated *context*: an immutable map from context-var tags to values, plus a parent pointer. Reading a context var walks the map chain from innermost binding outward, returning the first match (or the default if no binding exists).

### Propagation

Two propagation events:

1. **At task spawn.** When an async proc is called and produces a Future, the new task inherits the caller's current context. Subsequent `withContext` introductions inside the new task are local to it.

2. **At suspend/resume.** When an async proc awaits a Future, the dispatcher captures the current context as part of the registered continuation. When the awaited Future completes, the dispatcher restores that context before resuming the awaiter. This is the load-bearing mechanism — it's why bindings survive `await`.

Both events are implemented entirely inside chronos's dispatcher and `AsyncCallback`. User code interacts via the declaration / binding / read API; the propagation is invisible.

### Concurrent isolation

Because each task has its own context chain, two concurrent tasks that don't explicitly share context can't interfere. Task A's `withCurrentUser(alice): ...` is invisible to task B running in parallel, even if both tasks share an OS thread.

### Cancellation

If a task is cancelled, its context goes out of scope when the task ends. `withName` blocks use Nim's normal `try/finally` exit semantics — a cancellation propagating through an `await` inside a `withName` body restores the prior binding on the way out, just like an exception would.

### Inheritance vs sharing

A task that calls a child task synchronously (via direct call) shares the same context chain as the caller until the child suspends. After suspension, the child has its own captured context (the caller's context at the suspension's `addCallback`). Mutations to the *child's* context chain (via nested `withContext` blocks) don't propagate back to the caller — they're scoped to the child's `withName` body.

This is **inherit-by-snapshot-at-suspend**, which matches Python contextvars and .NET ExecutionContext.

## Implementation sketch

### Storage

An immutable persistent linked list of `(tag, value)` bindings per task. `withContext` prepends a node; reading walks the chain. O(n) read where n is the number of bound tags in scope. For typical use (1–5 bindings), this is faster than a hash map and produces no allocations beyond the list nodes.

```nim
type
  ContextNode = ref object
    tag: pointer            # type-tag identity (typeId or similar)
    valueRef: pointer       # erased value pointer
    next: ContextNode

  AsyncContext* = distinct ContextNode    # opaque
```

Persistent-map upgrade (HAMT) is a future optimization if profiling shows the linked list dominates for users with many bindings.

### Dispatcher integration

Extend `AsyncCallback` with a context field:

```nim
type AsyncCallback* = object
  function: CallbackFunc
  udata: pointer
  context: ContextNode      # NEW; nil when no bindings exist
```

`addCallback` captures the current context at registration time:

```nim
proc addCallback*(future: FutureBase, cb: CallbackFunc, udata: pointer) =
  # ... existing ...
  future.internalCallback = AsyncCallback(
    function: cb, udata: udata,
    context: currentContext())   # NEW: capture context
```

The dispatcher restores context before firing each callback:

```nim
proc fireCallback(cb: AsyncCallback) =
  let prev = currentContext()
  setCurrentContext(cb.context)
  try:
    cb.function(cb.udata)
  finally:
    setCurrentContext(prev)
```

Spawn-time inheritance happens naturally: when an async proc is first called, it runs with whatever context the caller had at the call site. The first `addCallback` inside that proc captures that context as the resume context.

### Type-tag identity

The `contextVar` macro generates a unique tag type per declaration via Nim's `distinct void` (which produces a fresh type per use):

```nim
# User writes:
contextVar currentUser: User = anonymous

# Macro expands to (roughly):
type CurrentUserTag = distinct void

template currentUser*(): User =
  contextGet[CurrentUserTag, User]()

template withCurrentUser*(v: User, body: untyped) =
  contextBind[CurrentUserTag, User](v, body)
```

The tag types serve as compile-time-unique keys. Two different `contextVar` declarations produce two different tags; the type system enforces non-collision. Library A's `contextVar foo: int` and library B's `contextVar foo: int` produce distinct tags despite the shared base name; a third party importing both gets a normal Nim name-shadowing warning rather than a silent semantic collision.

The dispatcher's context-node lookup uses the tag's `typeId` (or equivalent compile-time-stable identifier) as the key. The macro pre-computes this and inlines it into the generated reader/binder.

### Estimated patch size

- `chronos/internal/asyncfutures.nim`: ~30 lines (extend `AsyncCallback`, modify `addCallback`)
- `chronos/internal/asyncengine.nim`: ~20 lines (context swap around callback fires)
- `chronos/contextvars.nim`: ~100 lines new (the `contextVar` macro, `withContext`, `currentContext` / `setCurrentContext` private helpers)
- Tests: ~150 lines covering propagation across awaits, inheritance at spawn, cancellation, isolation between concurrent tasks
- Documentation: ~100 lines (user guide + API reference)

Total: ~400 LoC. Mostly mechanical; no changes to chronos's async transform or to existing user-facing APIs.

## Migration / compatibility

**Zero breaking changes.** All current chronos APIs work unchanged. CLS is opt-in via `contextVar` declarations. Async procs that never declare or read a context var pay nothing beyond the per-callback context pointer (which is `nil` for them, so the context swap during callback fire is two `nil` writes — branch-predictor-friendly noise).

**Cooperation with `multisync`** (chronos's sync/async dual-form pragma): synchronous variants don't have a dispatcher and therefore can't propagate context. Reading a context var from a `multisync`'d synchronous body returns the default. Document this clearly.

**Thread interaction**: chronos's dispatcher is single-thread-per-loop. Each dispatcher has its own current-context. Threads don't share context. Multi-threaded scenarios use existing chronos thread-coordination primitives; CLS is per-dispatcher.

## Alternatives considered

### A. Python-style `ContextVar[T]` runtime object

The familiar form:

```nim
let currentUser = newContextVar[User](anonymous)
currentUser.set(authedUser)
let u = currentUser.get()
```

**Why rejected**: requires a runtime `ContextVar` object per declaration; allocates; uses object identity as the dispatcher's lookup key. Loses Nim's compile-time collision detection (`ContextVar('user_id')` and `ContextVar('user_id')` in different modules silently coexist as different runtime objects; debugging is name-string-based).

The generative-phantom-type design preserves Python's user-facing ergonomics (one-line declaration, `name()` to read, `withName(v): body` to bind) while eliminating the runtime object and shifting collision detection to compile time. Strictly better implementation under a familiar surface.

### B. Imperative `set` / `reset` / `Token` API

Python's `contextvars` exposes:

```nim
let token = cv.set(v)
do_work()
cv.reset(token)
```

…in addition to scoped binding. The token records the prior binding for explicit reversal.

**Why omitted from MVP**: every use case for `set`/`reset` is covered by `withName`, which uses Nim's `try/finally` for the same effect at the syntactic-block level. Including `set`/`reset` adds API surface, invites the anti-pattern of binding-without-reset (the binding sticks for the rest of the task, looks like global state, debugs like global state), and undermines the design's positioning of scoped binding as the canonical mental model.

If a specific use case demands token-based reset (e.g., installing a binding in one function and reverting it in another), it's a strict addition rather than a redesign — `set` / `reset` / `Token` can land in a follow-up patch without disturbing the MVP.

### C. Effect-system enforcement of "binding required"

A truly maximal design would allow declaring "this function requires context var X to be bound" as a Nim effect:

```nim
proc readUser() {.requires: currentUser.} =
  echo currentUser()
```

…with the compiler verifying every caller of `readUser` is either also `requires: currentUser`-annotated or wraps the call in `withCurrentUser`. Static elimination of "default returned because nobody set the binding" bugs.

**Why omitted**: Nim doesn't have user-defined effects natively; this would require a typed-pass macro performing whole-program effect inference. Substantial complexity for a feature most users won't reach for. Worth revisiting if chronos picks up effect-system extensions for other reasons.

### D. `Context.run(ctx, callable)` for explicit context switching

Python's API includes `ctx.run(func)` to execute `func` with a specific context. Useful for trampolining and for tooling that snapshots-and-restores contexts.

**Why omitted from MVP**: niche; not needed for the common-case async propagation. Easy to add later via `withContext(snapshotted_ctx): body` if it surfaces as a real need.

### E. Per-Future context attachment instead of per-callback

Storing the context on the `FutureBase` instead of on each `AsyncCallback`. Slightly less memory (one pointer per Future vs one per callback) but breaks the "each awaiter captures its own context at registration" semantics: two awaiters of the same Future would see the same context (whichever was registered last) instead of each seeing their own.

**Why rejected**: the per-callback design is semantically correct; the per-Future design is a memory micro-optimization that introduces a subtle bug. Memory cost of per-callback is one pointer per scheduled continuation — negligible vs. the AsyncCallback's existing overhead.

## Risks and open questions

1. **Naming.** `contextVar` is one option; others include `taskLocal`, `asyncLocal`, `parameter`. The chronos maintainers should pick the one that best fits their naming conventions. The implementation is naming-agnostic.

2. **`contextGet` / `contextBind` exposure.** The macro-generated reader/binder calls into internal helpers. Should those helpers be exported for advanced users (and tools like profilers / debuggers that want to introspect contexts), or kept fully private? My weak recommendation: keep private for MVP; export if a real consumer surfaces.

3. **Persistent-map upgrade timing.** The MVP uses a linked-list context. For users with dozens of bound vars in deep call stacks, this becomes a bottleneck. Upgrading to a HAMT or similar persistent map is mechanical (the API doesn't change). Defer until profiling justifies it.

4. **`closure` iterator interaction.** `withContext` uses a `try/finally` around the body. Nim's closure iterators have well-defined `finally` semantics, but explicit testing for `yield` inside `withContext` is worth including in the test suite to catch any future iterator-transform changes that could break the binding scope.

5. **Cancellation callback context.** Should `cancelCallback=` also capture/restore context? Symmetric with `addCallback` says yes; pragmatic concern that cancellation handlers might want canceller's context says no. Open question; my weak preference is propagate-for-symmetry, but it's a small detail to settle in PR review.

6. **Performance baseline.** The patch adds one pointer per `AsyncCallback` and two pointer writes per callback fire. We should produce microbenchmarks comparing chronos before/after the patch on a representative workload (e.g., a high-throughput async server's request loop) and include the numbers in the PR.

## Prior art and references

- **Python contextvars** (PEP 567): https://peps.python.org/pep-0567/
- **.NET AsyncLocal\<T\>** + ExecutionContext: https://learn.microsoft.com/en-us/dotnet/api/system.threading.asynclocal-1
- **Kotlin CoroutineContext**: https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlinx.coroutines/-coroutine-context/
- **Rust tokio task_local!**: https://docs.rs/tokio/latest/tokio/macro.task_local.html
- **Node.js AsyncLocalStorage**: https://nodejs.org/api/async_context.html
- **Scheme parameterize / Racket parameters**: https://docs.racket-lang.org/reference/parameters.html

## Reference implementation

A working reference implementation will be available at github.com/coreyleavitt/chronos before the PR opens; this RFC documents the design first to gather feedback on shape before investment in code review.

The first downstream consumer is `fresco` (a Nim terminal-UI kernel), which currently maintains a ~150-line CLS-substrate workaround (`{.task.}` pragma macro + `taskAwait` helper). After this patch lands, fresco's substrate becomes ~3 lines of `contextVar` declarations. The fresco codebase will serve as the integration test for the design.

---

*Comments, objections, design alternatives, and acceptance-blocking concerns are all welcomed before code review begins.*
