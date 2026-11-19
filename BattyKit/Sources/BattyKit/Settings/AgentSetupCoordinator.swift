// AgentSetupCoordinator.swift

import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "AgentSetupCoordinator")

/// Silently refreshes guidance the user installed from Settings after an update.
/// Planning, hashing and installing run off the main actor.
public final class AgentSetupCoordinator {
    private let identity: @Sendable () -> AgentGuidanceIdentity?
    private let installer: @Sendable () -> AgentGuidanceInstaller
    private let store: AgentSetupRecordStore
    private let now: @Sendable () -> Date

    public init(
        identity: @escaping @Sendable () -> AgentGuidanceIdentity?,
        installer: @escaping @Sendable () -> AgentGuidanceInstaller,
        store: AgentSetupRecordStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.identity = identity
        self.installer = installer
        self.store = store
        self.now = now
    }

    @discardableResult
    public func runLaunchCheck() async -> AgentSetupDecision {
        guard let record = store.load(), !record.hosts.isEmpty else { return .nothing }
        let identity = identity
        let installer = installer
        let computed = await Task.detached { () -> (AgentInstallPlan, String)? in
            guard let identity = identity(), let fingerprint = AgentGuidanceFingerprint.make(identity: identity) else { return nil }
            return (installer().plan(identity: identity), fingerprint)
        }.value
        guard let (plan, fingerprint) = computed else {
            logger.notice("No bundled agent guidance; skipping the agent guidance refresh")
            return .nothing
        }
        let decision = AgentSetupPolicy.decide(record: record, plan: plan, fingerprint: fingerprint)
        if case let .refresh(plan) = decision {
            let report = await Task.detached { installer().apply(plan) }.value
            logger.notice("Refreshed agent guidance:\n\(report.render(), privacy: .public)")
            store.save(record.recording(plan: plan, report: report, fingerprint: fingerprint, at: now()))
        }
        return decision
    }
}
