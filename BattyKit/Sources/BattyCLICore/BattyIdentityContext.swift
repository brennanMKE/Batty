// BattyIdentityContext.swift

import Foundation

/// The `batty id` payload (alias `whoami`) — this pane's session/pane/tab
/// identity, read from environment alone (#0257 Foundation §3, built by
/// #0281). No app round-trip: works even when the app or broker is
/// unreachable.
///
/// `nonisolated` at the type level — see `BattyContextEnvironment`'s doc for
/// why; `batty id` calls `resolve(from:)` from a `nonisolated func run()`.
public nonisolated struct BattyIdentityContext: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let paneID: UUID
    public let tabID: UUID

    public init(sessionID: UUID, paneID: UUID, tabID: UUID) {
        self.sessionID = sessionID
        self.paneID = paneID
        self.tabID = tabID
    }

    /// v1 is env-only (#0281 Decided 2026-07-26, carried from #0257/#0274):
    /// no pty-device-path fallback for a scrubbed environment (`sudo`, a
    /// nested shell that doesn't inherit). Either failure case reports
    /// which key(s) were the problem, not just "failed".
    public enum ResolutionError: Error, Equatable, CustomStringConvertible {
        case missing([BattyContextEnvironmentKey])
        case malformed([BattyContextEnvironmentKey: String])

        public var description: String {
            switch self {
            case let .missing(keys):
                let names = keys.map(\.rawValue).sorted().joined(separator: ", ")
                return "not set: \(names) (run inside a Batty pane, or coordinate a shell that inherits its environment)"
            case let .malformed(keys):
                let parts = keys.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: ", ")
                return "not a valid UUID: \(parts)"
            }
        }
    }

    /// Resolves from `environment`, defaulting to the real process
    /// environment; tests inject a fixture dictionary. Requires all three
    /// vars present and well-formed — `batty id`'s entire value is a
    /// complete identity triple, so a partial result would be misleading.
    public static func resolve(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Result<BattyIdentityContext, ResolutionError> {
        var values: [BattyContextEnvironmentKey: UUID] = [:]
        var missing: [BattyContextEnvironmentKey] = []
        var malformed: [BattyContextEnvironmentKey: String] = [:]

        for key in BattyContextEnvironmentKey.allCases {
            switch BattyContextEnvironment.lookup(key, in: environment) {
            case .absent:
                missing.append(key)
            case let .malformed(raw):
                malformed[key] = raw
            case let .value(uuid):
                values[key] = uuid
            }
        }

        // Malformed takes priority: a present-but-garbled value is a more
        // actionable report than lumping it in with "not set".
        guard malformed.isEmpty else { return .failure(.malformed(malformed)) }
        guard missing.isEmpty else { return .failure(.missing(missing)) }

        guard let sessionID = values[.sessionID],
              let paneID = values[.paneID],
              let tabID = values[.tabID]
        else {
            // Unreachable given the guards above — every key was resolved
            // into `values` or already reported as missing/malformed.
            return .failure(.missing(BattyContextEnvironmentKey.allCases))
        }

        return .success(BattyIdentityContext(sessionID: sessionID, paneID: paneID, tabID: tabID))
    }
}
