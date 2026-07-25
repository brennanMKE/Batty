// BrokerConnectionLifecycle.swift

/// Distinguishes the two terminal signals a persistent `NSXPCConnection` can
/// deliver and the response each demands (#0272 item 1):
///
/// - `interruption` — the peer process died (e.g. the broker crashed or was
///   killed) but the `NSXPCConnection` object itself is still usable.
///   Sending a further message on it is what causes launchd to relaunch the
///   on-demand broker, so the correct response is retrying the outstanding
///   work *over the same connection*.
/// - `invalidation` — the connection can never be used again (explicit
///   `invalidate()`, or a failure XPC judged unrecoverable). The object must
///   be discarded and a brand-new `NSXPCConnection` created.
///
/// Conflating the two — routing both to the same handler — yields either a
/// reconnect loop (retrying calls on a connection that will never deliver
/// them again) or a permanently dead connection (discarding a connection
/// that was about to recover on its own). Kept as a pure enum → action
/// mapping, with no `NSXPCConnection` involved, so the dispatch decision is
/// unit-testable without any real XPC connection; `AppXPCCoordinator` is the
/// only caller that turns the returned action into real work.
public nonisolated enum BrokerConnectionSignal: Sendable, Equatable {
    case interruption
    case invalidation
}

public nonisolated enum BrokerConnectionResponse: Sendable, Equatable {
    /// Peer died, connection reusable — retry the outstanding call on the
    /// existing `NSXPCConnection`.
    case retryOverExistingConnection
    /// Connection permanently dead — discard it and build a new one.
    case rebuildConnection
}

public nonisolated enum BrokerConnectionLifecycle {
    public static func response(for signal: BrokerConnectionSignal) -> BrokerConnectionResponse {
        switch signal {
        case .interruption:
            return .retryOverExistingConnection
        case .invalidation:
            return .rebuildConnection
        }
    }
}
