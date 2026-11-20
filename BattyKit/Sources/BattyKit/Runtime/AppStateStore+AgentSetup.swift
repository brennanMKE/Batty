// AppStateStore+AgentSetup.swift

import Foundation

extension AppStateStore {
    /// Refreshes agent guidance the user installed from Settings after an update.
    /// Skipped for UI-test launches.
    public func startAgentSetupCheck(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard !environment.keys.contains(where: { $0.hasPrefix("BATTY_UI_TEST_") }) else { return }
        let coordinator = AgentSetupCoordinator(
            identity: AgentIntegrationModel.liveIdentity,
            installer: AgentIntegrationModel.liveInstaller,
            store: AgentSetupRecordStore(defaults: .standard)
        )
        Task { await coordinator.runLaunchCheck() }
    }
}
