// NoEndpointRegisteredDecision.swift

/// What the CLI's connect dance (`AppConnectDance.resolveEndpoint`) should do
/// when the broker is reachable but reports no registered app endpoint
/// (#0361). That state is ambiguous on its own — it means either "no app is
/// running, safe to launch one" or "the app is running but hasn't
/// registered" (a broker restart it hasn't caught up with, or an exhausted
/// `BrokerReconnectBudget`) — and the two demand opposite responses.
/// Launching in the second case spawns a duplicate process alongside the
/// one already running, which is the defect #0361 reports: every `batty`
/// invocation looked like a broker miss and launched another instance.
///
/// Kept as a pure mapping from a single `Bool` — whether
/// `NSRunningApplication` reports a process for the bundle id — with no
/// `NSRunningApplication` involved here, so the branch is unit-testable
/// without a real running process.
public nonisolated enum NoEndpointRegisteredAction: Sendable, Equatable {
    /// No process for the bundle id is running: launch one and poll for its
    /// registration. Unchanged from the CLI's pre-#0361 behavior.
    case launchAndPoll
    /// A process is already running: launching would create a duplicate.
    /// Poll for it to (re-)register instead, and fail with a clear
    /// diagnostic — never a silent launch — if it never does.
    case waitForReregistration
}

public nonisolated enum NoEndpointRegisteredDecision {
    public static func action(isAppRunning: Bool) -> NoEndpointRegisteredAction {
        isAppRunning ? .waitForReregistration : .launchAndPoll
    }
}
