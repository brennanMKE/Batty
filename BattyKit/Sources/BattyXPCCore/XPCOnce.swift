// XPCOnce.swift

import Foundation

/// Guards the single transition from "waiting" to "finished" against a
/// reply block, an error handler, and an interruption/invalidation handler
/// all being capable of firing for the same outstanding call
/// (`docs/xpc/xpc-cli-architecture.md` "Request/reply" — the `ResumeOnce`
/// pattern). Without it, an error handler firing after a reply already did
/// traps with `SWIFT TASK CONTINUATION MISUSE`; a timeout racing a reply is
/// exactly that situation.
///
/// Every caller here reaches this from a Foundation completion-handler
/// closure marked `@Sendable` (the reply block, the error handler, the
/// interruption/invalidation handler), never from `self`'s own isolation —
/// `@unchecked Sendable` holds because every mutation goes through `lock`.
///
/// `wait(timeout:)` blocks its calling thread — correct for the `batty`
/// CLI's synchronous `ParsableCommand.run()`, wrong for the app: this type
/// lives in shared `BattyXPCCore`, which the GUI app also links, so a
/// future app-side caller must not call `wait(timeout:)` from the main
/// actor — XPC's reply delivery does not require the main thread to be
/// free, but blocking it here would freeze the UI regardless.
public nonisolated final class XPCOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var value: Value
    private let semaphore = DispatchSemaphore(value: 0)

    public init(defaultValue: Value) {
        self.value = defaultValue
    }

    /// Records `value` if nothing has finished yet; a second or later call
    /// is silently ignored. Wakes `wait(timeout:)`.
    public func finish(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        self.value = value
        semaphore.signal()
    }

    /// Blocks the calling thread until `finish(_:)` is called or `timeout`
    /// elapses, then returns whatever value is on hand — the constructor's
    /// default if nothing ever finished. Callers are expected to invalidate
    /// the underlying `NSXPCConnection` on return so a late-arriving
    /// handler after a timeout does not leak the connection.
    public func wait(timeout: TimeInterval) -> Value {
        _ = semaphore.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
