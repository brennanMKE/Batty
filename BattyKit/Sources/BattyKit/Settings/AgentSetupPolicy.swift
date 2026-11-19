// AgentSetupPolicy.swift

import Foundation

public nonisolated enum AgentSetupDecision: Sendable, Equatable {
    /// Already restricted to the installed hosts whose guidance is stale.
    case refresh(AgentInstallPlan)
    case nothing
}

/// Decides what a launch does about agent guidance. Only hosts the user
/// installed are ever refreshed; nothing is offered.
public nonisolated enum AgentSetupPolicy {
    public static func decide(record: AgentSetupRecord?, plan: AgentInstallPlan, fingerprint: String) -> AgentSetupDecision {
        guard let record else { return .nothing }
        let stale = Set(record.installedHosts.filter { record.installed($0)?.fingerprint != fingerprint })
        let restricted = plan.restricted(to: stale)
        return restricted.actions.isEmpty ? .nothing : .refresh(restricted)
    }
}
