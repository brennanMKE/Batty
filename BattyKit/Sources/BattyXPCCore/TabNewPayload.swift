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

    public init(paneID: UUID?, sourceTabID: UUID?, command: String?, workingDirectory: String?, background: Bool?) {
        self.paneID = paneID
        self.sourceTabID = sourceTabID
        self.command = command
        self.workingDirectory = workingDirectory
        self.background = background
    }
}

/// Later builds may add optional fields; decoders ignore unknown keys.
public nonisolated struct TabNewReply: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let paneID: UUID
    public let tabID: UUID

    public init(sessionID: UUID, paneID: UUID, tabID: UUID) {
        self.sessionID = sessionID
        self.paneID = paneID
        self.tabID = tabID
    }
}
