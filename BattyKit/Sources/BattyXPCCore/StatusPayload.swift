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
    /// #0361: which on-disk app bundle answered, from that process's own
    /// `Bundle.main.bundleURL` — ground truth from the actual peer, not a
    /// CLI-side guess. Added specifically because #0361's failure mode was
    /// undiagnosable: nothing told the user which of several bundles
    /// sharing `co.sstools.Batty` (DerivedData debug builds, the installed
    /// app, ...) they were actually talking to. `batty status` now prints
    /// it.
    public let bundlePath: String
    /// That process's `CFBundleShortVersionString` (falls back to
    /// `CFBundleVersion`, then `"unknown"` if neither resolves).
    public let appVersion: String

    public init(pid: Int32, uptimeSeconds: Double, windowCount: Int, sessionCount: Int, tabCount: Int, bundlePath: String, appVersion: String) {
        self.pid = pid
        self.uptimeSeconds = uptimeSeconds
        self.windowCount = windowCount
        self.sessionCount = sessionCount
        self.tabCount = tabCount
        self.bundlePath = bundlePath
        self.appVersion = appVersion
    }

    /// The value `bundlePath`/`appVersion` take when the answering app did
    /// not send them — the same sentinel `appVersion`'s own doc comment
    /// already names for an unresolvable version.
    public static let unknownField = "unknown"

    /// #0508: hand-written so the two fields #0361 added decode as absent
    /// rather than as a hard failure. The app encodes and the CLI decodes,
    /// and they are not guaranteed to be the same build — a stale running
    /// app is the exact situation `bundlePath` was added to diagnose, and
    /// there is no protocol-version field in `XPCRequest`/`XPCResponse` to
    /// negotiate with. With synthesized `Decodable`, a pre-#0361 app's
    /// five-field reply threw, so `batty status` reported a generic error
    /// instead of naming the old app answering on `co.sstools.Batty`.
    ///
    /// The five original fields stay required: an app that cannot supply
    /// those is not a Batty this CLI can talk to at all. Encoding is
    /// unchanged — an old CLI reading a new app's reply already ignores
    /// unknown keys.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pid = try container.decode(Int32.self, forKey: .pid)
        uptimeSeconds = try container.decode(Double.self, forKey: .uptimeSeconds)
        windowCount = try container.decode(Int.self, forKey: .windowCount)
        sessionCount = try container.decode(Int.self, forKey: .sessionCount)
        tabCount = try container.decode(Int.self, forKey: .tabCount)
        bundlePath = try container.decodeIfPresent(String.self, forKey: .bundlePath) ?? Self.unknownField
        appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion) ?? Self.unknownField
    }
}
