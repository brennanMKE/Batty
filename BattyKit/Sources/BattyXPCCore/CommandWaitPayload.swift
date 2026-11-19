// CommandWaitPayload.swift

import Foundation

/// How a `--wait` on `pane split -c` or `tab new -c` ended.
public nonisolated enum CommandWaitResult: String, Codable, Sendable, Equatable {
    case exited
    case timedOut
    case shellNotReady
    case notStarted
    case tabClosed
}

public nonisolated enum CommandWaitDefaults {
    public static let timeoutSeconds: Double = 600
}
