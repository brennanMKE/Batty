// TabNewPayload.swift

import Foundation

/// Request/reply payloads for the `tabNew` XPC verb. `nonisolated` for the
/// same reason as `TabFocusPayload.swift`: under the package's
/// `.defaultIsolation(MainActor.self)` the synthesized `Codable`
/// conformance would otherwise be main-actor-isolated and unusable from
/// XPC's own queues.
///
/// `paneID == nil` means the app targets its focused Pane. `sourceTabID` is
/// the caller's `BATTY_TAB_ID`; the app inherits its working directory only
/// when that Tab is in the target Pane, else the Pane's active Tab's.
public nonisolated struct TabNewRequest: Codable, Sendable, Equatable {
    public let paneID: UUID?
    public let sourceTabID: UUID?
    public let command: String?
    public let workingDirectory: String?
    public let background: Bool?
    /// Type `command` into a shell and reply once it finishes (#0668).
    public let wait: Bool?
    public let waitTimeoutSeconds: Double?

    public init(paneID: UUID?, sourceTabID: UUID?, command: String?, workingDirectory: String?, background: Bool?, wait: Bool? = nil, waitTimeoutSeconds: Double? = nil) {
        self.paneID = paneID
        self.sourceTabID = sourceTabID
        self.command = command
        self.workingDirectory = workingDirectory
        self.background = background
        self.wait = wait
        self.waitTimeoutSeconds = waitTimeoutSeconds
    }
}

/// Later builds may add optional fields; decoders ignore unknown keys.
public nonisolated struct TabNewReply: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let paneID: UUID
    public let tabID: UUID
    /// Set only with `wait`.
    public let exitCode: Int?
    public let durationMs: Int?
    public let waitResult: CommandWaitResult?

    public init(sessionID: UUID, paneID: UUID, tabID: UUID, exitCode: Int? = nil, durationMs: Int? = nil, waitResult: CommandWaitResult? = nil) {
        self.sessionID = sessionID
        self.paneID = paneID
        self.tabID = tabID
        self.exitCode = exitCode
        self.durationMs = durationMs
        self.waitResult = waitResult
    }
}
