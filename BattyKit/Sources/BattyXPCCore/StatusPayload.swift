// StatusPayload.swift

import Foundation

/// Payload for the `status` verb (#0271) — the first XPC verb that returns
/// real app state instead of a bare acknowledgement, carried inside
/// `XPCResponse.payload`. "At least pid, uptime, and window/session counts"
/// per the issue; `tabCount` is included because `AppStateStore` already
/// computes it the same way for `applicationShouldTerminate`'s log line.
///
/// `nonisolated` at the type level for the same reason as `XPCRequest`/
/// `XPCResponse` (`XPCMessages.swift`): under this package's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, an unannotated struct's
/// synthesized `Codable` conformance is itself main-actor-isolated, which
/// fails to compile from XPC's own queues.
public nonisolated struct StatusPayload: Codable, Sendable, Equatable {
    public let pid: Int32
    public let uptimeSeconds: Double
    public let windowCount: Int
    public let sessionCount: Int
    public let tabCount: Int

    public init(pid: Int32, uptimeSeconds: Double, windowCount: Int, sessionCount: Int, tabCount: Int) {
        self.pid = pid
        self.uptimeSeconds = uptimeSeconds
        self.windowCount = windowCount
        self.sessionCount = sessionCount
        self.tabCount = tabCount
    }
}
