// PendingRequestRegistry.swift

import BattyXPCCore
import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "PendingRequestRegistry")

/// Tracks in-flight `AppServiceProtocol.perform` reply closures so the app
/// can answer them with a distinguishable "app is terminating" response
/// before it quits (#0272 item 4), instead of letting the connection drop
/// out from under a call that is still awaiting its reply.
///
/// Without this, a CLI mid-request when the app quits sees only a raw
/// connection interruption/invalidation — indistinguishable from "the app
/// was never reachable" (`XPCExitCode.appUnavailable`, 3). Replying with
/// `XPCTerminationSignal.appTerminating` first lets the CLI report
/// `XPCExitCode.sessionTerminated` (5) instead.
///
/// Every reply block passed in here is the `@escaping @Sendable
/// (Data) -> Void` XPC hands `AppXPCService.perform`, called from
/// `Task { @MainActor ... }` after the request is decoded — this registry's
/// own methods run under `lock`, not on any particular actor, so `register`/
/// `resolve`/`terminateAll` are safe to call from `AppXPCService`'s
/// `nonisolated` context directly.
public nonisolated final class PendingRequestRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UUID: @Sendable (Data) -> Void] = [:]

    public init() {}

    /// Number of requests currently awaiting a reply. Exposed for tests and
    /// for `log stream` visibility into in-flight work at shutdown time.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    /// Registers `reply` under a fresh id and returns it — the caller keeps
    /// the id to pair with a later `resolve(_:with:)`.
    public func register(_ reply: @escaping @Sendable (Data) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        pending[id] = reply
        lock.unlock()
        return id
    }

    /// Delivers `data` to the reply registered under `id`, if it is still
    /// pending, and removes it. Returns `false` (without calling `reply`)
    /// if `id` was already resolved — by a normal reply or by
    /// `terminateAll()` — which is the guard against double-invoking a
    /// reply block XPC has already delivered once.
    @discardableResult
    public func resolve(_ id: UUID, with data: Data) -> Bool {
        let reply: (@Sendable (Data) -> Void)? = {
            lock.lock()
            defer { lock.unlock() }
            return pending.removeValue(forKey: id)
        }()
        guard let reply else { return false }
        reply(data)
        return true
    }

    /// Answers every still-pending request with the shared
    /// `XPCTerminationSignal.appTerminating` response and clears the
    /// registry. Idempotent — a request already resolved before this runs
    /// (the normal case for a call that finished before quit) is not
    /// touched twice, since it was already removed by `resolve(_:with:)`.
    public func terminateAll() {
        let snapshot: [UUID: @Sendable (Data) -> Void] = {
            lock.lock()
            defer { lock.unlock() }
            let values = pending
            pending.removeAll()
            return values
        }()
        guard !snapshot.isEmpty else { return }
        logger.info("terminateAll: notifying \(snapshot.count, privacy: .public) in-flight request(s) of app termination")
        let response = XPCResponse(ok: false, error: XPCTerminationSignal.appTerminating)
        let data = (try? JSONEncoder().encode(response)) ?? Data()
        for reply in snapshot.values {
            reply(data)
        }
    }
}
