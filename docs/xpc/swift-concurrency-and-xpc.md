# Swift 6 concurrency and XPC

> **Vendored copy — not a Batty document.** Copied 2026-07-24 from
> `RemoteControl/docs/swift-concurrency-and-xpc.md` (a sibling, throwaway,
> read-only checkout at `/Users/brennan/Developer/brennanMKE/RemoteControl`)
> for Batty issue [#0267](../../issues/0267.md). It describes the
> RemoteControl XPC prototype — a different app — not Batty; the
> "must rename" / "copy verbatim" markers throughout are written for that
> porting exercise. The body below is unedited from the source.
>
> **Any bare `#NNNN` below is a RemoteControl issue** (that project's own
> `issues/0001`–`issues/0031` tracker), never a Batty issue — Batty's
> tracker uses the identical `#NNNN` form for a disjoint set of numbers.
> Links to files this vendoring did not copy (RemoteControl's `issues/`
> folder, its repo-root `README.md`) will not resolve; see the source
> checkout above if it still exists.

The traps in this document cost more time than every other part of the XPC work
combined, and the first one is the reason: **it crashes at runtime with no
compiler warning, in the code path that would have logged the error.**

Everything here assumes a target built with:

```
SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
SWIFT_STRICT_CONCURRENCY = complete
```

which is a reasonable default for a modern app target, and is the configuration
that makes the first trap possible.

## 1. Objective-C callback closures must be `@Sendable`, or they trap

### The symptom

`EXC_BREAKPOINT` / `SIGTRAP`. No exception, no error, no log line. In this
project it appeared while trying to verify a *different* fix, which is the only
reason it was found at all.

The crashed-thread stack, which is the signature to recognise:

```
_dispatch_assert_queue_fail
dispatch_assert_queue
_swift_task_checkIsolatedSwift
swift_task_isCurrentExecutorWithFlagsImpl
closure #1 in AppXPCServer.registerWithBroker()
__NSXPCCONNECTION_IS_CALLING_OUT_TO_ERROR_BLOCK__
```

Read it bottom-up: XPC is calling out to an error block, on an XPC queue; the
Swift runtime checks whether it is on the closure's expected executor; it is
not; the assertion fails; the process dies.

### The cause

Foundation declares `remoteObjectProxyWithErrorHandler`'s parameter as a plain
`(any Error) -> Void`. Not `@Sendable`. So a closure literal written inside a
`@MainActor` method **inherits main-actor isolation**, and the compiler emits an
isolation assertion at the closure's entry point.

From the type system's point of view this is correct: a non-`Sendable` closure
parameter should only ever be called from the isolation domain that created it.
Objective-C APIs simply do not honour that. Strict concurrency is fully
satisfied and the code still dies.

`interruptionHandler` and `invalidationHandler` are `() -> Void` and have exactly
the same defect.

### The fix

Mark them `@Sendable`, which makes them `nonisolated`, then hop deliberately:

```swift
let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable [weak self] error in
    Task { @MainActor [weak self] in
        self?.handleBrokerFailure(error.localizedDescription)
    }
}

connection.interruptionHandler = { @Sendable [weak self] in
    Task { @MainActor [weak self] in self?.handleInterruption() }
}
connection.invalidationHandler = { @Sendable [weak self] in
    Task { @MainActor [weak self] in self?.handleInvalidation() }
}
```

The `@Sendable` is doing the work. The `Task { @MainActor … }` is how you get
back to your actor to touch state.

### Why this was so expensive

**The crash happened inside the handler that would have reported the problem.**
The visible symptom was "registration silently does nothing" — no error logged,
because the process was being killed in the error path. Every hypothesis pointed
at the broker, the plist, launchd, and `SMAppService`. The bug was three lines
away from the log statement that would have named it.

### Audit rule

> On a `MainActor`-default target, **every** Objective-C or C callback closure that
> the framework may invoke off the main queue must be explicitly `@Sendable`.

That is not limited to XPC. It covers `NotificationCenter` observers,
`NSMetadataQuery`, `DispatchSource` handlers, `URLSession` completion blocks,
`FSEvents`, `SMAppService` callbacks — anything with a completion handler
declared in Objective-C. Grep for `{ [weak self]` and check each one against
whether the framework promises main-queue delivery.

### Protect yourself in the protocols you own

Declare every reply block in your own `@objc` protocols as `@escaping @Sendable`:

```swift
@objc public protocol AppServiceProtocol {
    func ping(reply: @escaping @Sendable (String) -> Void)
    func perform(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}
```

Do this on the first day. In this project it was done in the second issue, before
any of the crashes, and the payoff was direct: **only the Foundation-supplied
handlers were ever exposed**, because every call site the project controlled had
the annotation enforced by the compiler. It costs nothing and it removes an
entire class of runtime crash from the code you write.

## 2. `nonisolated` on pure helpers

On a `MainActor`-default target, a plain `enum` of static functions is
main-actor isolated whether you meant it or not. Two things break:

**Detached work cannot call it.** A file hasher invoked from a background task
has to hop to the main actor for every chunk, which defeats the purpose — or
fails to compile, which is the better outcome.

**Tests cannot call it.** The failure reads:

```
error: call to main actor-isolated static method 'parse' in a synchronous nonisolated context
```

Mark anything genuinely pure as `nonisolated`:

```swift
nonisolated enum FileDigest {
    static func compute(…) throws -> String { … }
}

nonisolated final class ProgressThrottle {
    …
}

nonisolated struct URLSchemeHandler {
    static func parse(_ url: URL) -> Request? { … }
}
```

The rule that works in practice: **if it takes values in and returns values out,
mark it `nonisolated`.** If it touches UI state or observable properties, leave
it on the main actor. Doing this as you write costs nothing; retrofitting it
means chasing isolation errors up through call sites.

## 3. Carrying a non-`Sendable` `NSXPCConnection` across isolation

`NSXPCConnection` is not `Sendable`. You will still need to hand one from a
delegate callback (which arrives on an XPC queue) to your main-actor state.

The transfer box:

```swift
/// Carries a non-Sendable value across an isolation boundary.
///
/// Sound here because exactly one side touches the value at a time: the
/// listener delegate hands the connection over and does not retain it.
private nonisolated struct Unsafely<Value>: @unchecked Sendable {
    let value: Value
}
```

Used at the boundary:

```swift
nonisolated func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection connection: NSXPCConnection
) -> Bool {
    let box = Unsafely(value: connection)
    Task { @MainActor in
        self.accept(box.value)
    }
    return true
}
```

`@unchecked Sendable` is a promise you are making to the compiler, so make it
only when you can state why it holds — and write that reason in the comment. Here
it holds because the delegate does not keep a reference after handing it over.

Prefer a narrow box like this over marking a whole type `@unchecked Sendable`.
The box's unsafety is one line and locally auditable; a type-level annotation
silences the checker everywhere forever.

## 4. Re-capturing an already-weak `self` inside a nested `Task`

This one produces a real compiler error rather than a crash, which is a mercy:

```
error: reference to captured var 'self' in concurrently-executing code
```

It happens when you capture `self` weakly, unwrap it, and then start a nested
`Task` that touches the unwrapped value — the unwrapped `self` is a `var` in the
enclosing scope, and the nested task captures it by reference.

The fix that reads best: **build the `@Sendable` emitter closures on the main
actor first**, each capturing `self` weakly exactly once, and hand *those* to the
detached task. The task then holds only closures, not `self`:

```swift
@MainActor
func beginDigest(_ path: String, sessionID: String) {
    // Built here, on the main actor. Each captures self weakly, once.
    let emitProgress: @Sendable (Double) -> Void = { [weak self] fraction in
        Task { @MainActor [weak self] in self?.send(.progress(fraction), to: sessionID) }
    }
    let emitResult: @Sendable (String) -> Void = { [weak self] digest in
        Task { @MainActor [weak self] in self?.send(.result(digest), to: sessionID) }
    }

    Task.detached {
        // No `self` here at all -- only two closures.
        try? FileDigest.compute(path, onProgress: emitProgress, onResult: emitResult)
    }
}
```

The alternatives — capturing an unowned reference, or threading a
`@MainActor`-isolated actor reference through — both work and both read worse.
Passing behaviour instead of identity across the boundary is the clearer shape,
and it makes the detached work independently testable, since it now takes plain
closures.

## 5. Memory, which concurrency will not save you from

Not a concurrency bug, but it lives in the same code and is worth the same
vigilance.

Streaming a large file with `FileHandle.read(upToCount:)` returns `NSData`-backed
`Data`, which lands in the enclosing autorelease pool. Inside a tight loop that
pool is **not drained until the loop finishes**, so every chunk stays alive to the
end. Hashing 1 GB grew RSS by **~940 MB** — precisely the unbounded growth that
streaming exists to prevent.

```swift
while true {
    let finished = try autoreleasepool {          // INSIDE the loop
        guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty
        else { return true }
        hasher.update(data: chunk)
        return false
    }
    if finished { break }
}
```

With the pool inside the loop: **+5.4 MB across 2.3 GB**.

There is no warning for this, no test that fails, and the feature works
correctly either way. It is only visible if you watch RSS while it runs. If you
write a streaming loop over Foundation I/O, measure it once.

## Quick reference

| Symptom | Cause | Fix |
|---|---|---|
| `SIGTRAP`, `_swift_task_checkIsolatedSwift` in the stack | Objective-C callback closure inherited main-actor isolation | `@Sendable` on the closure, then `Task { @MainActor … }` |
| Silent failure with nothing logged | The crash is *in* the error handler | Same as above; suspect it whenever a failure path produces no output |
| `call to main actor-isolated … in a synchronous nonisolated context` | Pure helper picked up default isolation | `nonisolated` on the type |
| `NSXPCConnection` cannot cross into a `Task` | Not `Sendable` | Narrow `@unchecked Sendable` box, with the reason written down |
| `reference to captured var 'self' in concurrently-executing code` | Nested `Task` re-capturing an unwrapped weak `self` | Build `@Sendable` emitter closures on the actor; pass those |
| Calls succeed but nothing arrives, no error | `remoteObjectInterface` / `exportedInterface` mismatch, or missing before `resume()` | Route both through one interface factory |
| RSS climbs with file size while streaming | `NSData`-backed `Data` accumulating in an undrained pool | `autoreleasepool` inside the read loop |
