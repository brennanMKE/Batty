// LMStudioDashboardTypes.swift

import Foundation

/// Connection-health pill state (`docs/design/lmstudio-dashboard-view.md`
/// §3.1). Ordered so a conformer can compute it as a simple priority chain
/// — see `LMStudioDashboardPaneContent.connectionState`.
public nonisolated enum LMStudioConnectionState: String, Sendable, Equatable {
    /// Initial phase, before the first `/api/v1/models` poll completes.
    case checking
    /// The `lms` CLI binary could not be located
    /// (`LMStudioCLI.resolveExecutableURL()` returned `nil`) — one of the
    /// three degraded states `issues/0313.md`'s Gotchas require. The
    /// Loaded Models panel still works (HTTP-only), but the live
    /// prediction feed and Engine Errors panel cannot.
    case notInstalled
    /// Two consecutive `/api/v1/models` poll failures — the server isn't
    /// answering (not running, or unreachable). Design doc §5's
    /// two-strike rule.
    case unreachable
    /// A log-stream subprocess exited unexpectedly while the pane is
    /// active and the server is reachable; a respawn is in flight.
    case reconnecting
    case connected
}

public nonisolated struct LMStudioLoadedModelSummary: Sendable, Equatable, Identifiable {
    public let instanceID: String
    public let modelKey: String
    public let displayName: String
    public let publisher: String?
    public let quantizationName: String?
    public let paramsString: String?
    public let sizeBytes: Int64?
    public let contextLength: Int?
    public let parallel: Int?

    public var id: String { instanceID }
}

public nonisolated struct LMStudioInFlightRequest: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let modelIdentifier: String
    public let startedAt: Date
}

public nonisolated struct LMStudioCompletionRecord: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let completedAt: Date
    public let modelIdentifier: String
    public let stats: LMStudioPredictionStats?
    /// `stats.promptTokensCount ÷` the model's loaded `context_length`,
    /// computed per-row (design doc §3.4) so it's unambiguous which
    /// model's context window is meant. `nil` when either figure is
    /// unavailable.
    public let contextPressure: Double?
}

/// Prompt Inspector opt-in ring entry (design doc §2.1 Option A, §6). Kept
/// entirely separate from `LMStudioCompletionRecord`'s 200-entry metadata
/// ring — sharing `id` with the corresponding completion so a view can
/// cross-reference the two, but never embedded in the metadata ring
/// itself, so the metadata ring's retained footprint never includes raw
/// prompt/completion text regardless of how long the inspector has been on.
public nonisolated struct LMStudioInspectorRecord: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let modelIdentifier: String
    public let completedAt: Date
    public let prompt: String?
    public let completion: String?
}

public nonisolated struct LMStudioEngineLogEntry: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let level: String?
    public let message: String?
    public let engineName: String?
}
