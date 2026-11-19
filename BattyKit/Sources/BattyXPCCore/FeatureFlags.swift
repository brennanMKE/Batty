// FeatureFlags.swift

import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "FeatureFlags")

/// One `Bool` per unfinished feature: on in Batty Beta, off in Prod, with no
/// other way to set it. See `docs/feature-flags.md`.
public nonisolated struct FeatureFlags: Sendable, Equatable {
    public var sharedProjectImages: Bool
    public var agentIntegration: Bool
    public var serverPane: Bool

    public init(sharedProjectImages: Bool, agentIntegration: Bool = false, serverPane: Bool = false) {
        self.sharedProjectImages = sharedProjectImages
        self.agentIntegration = agentIntegration
        self.serverPane = serverPane
    }

    /// Present in the environment only for UI-test runs; the same variable
    /// `UITestDriver.scriptEnvVar` names.
    public static let uiTestEnvironmentVar = "BATTY_UI_TEST_SCRIPT"

    /// When "1" alongside `uiTestEnvironmentVar`, forces `serverPane` off. It
    /// can never force a flag on.
    public static let uiTestForceServerPaneOffVar = "BATTY_UI_TEST_FORCE_SERVER_PANE_OFF"

    /// A nil or unknown identifier fails closed.
    public static func resolved(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> FeatureFlags {
        guard let variant = ServiceNames.Variant(bundleIdentifier: bundleIdentifier) else {
            logger.error("feature flags off: bundle identifier \(bundleIdentifier ?? "<nil>", privacy: .public) is no known Batty variant")
            return FeatureFlags(sharedProjectImages: false, agentIntegration: false, serverPane: false)
        }
        let isBeta = variant == .beta
        return applyingUITestOverride(
            FeatureFlags(sharedProjectImages: isBeta, agentIntegration: isBeta, serverPane: isBeta),
            environment: environment
        )
    }

    /// For the `batty` CLI, a bare Mach-O with no `Info.plist`: derived from
    /// the compile-time `ServiceNames.current`. Always off under `swift test`,
    /// so code branching on it takes the flags as a parameter. The app never
    /// reads this; it uses `resolved(bundleIdentifier:)`.
    public static var current: FeatureFlags {
        let isBeta = ServiceNames.current == .beta
        return FeatureFlags(sharedProjectImages: isBeta, agentIntegration: isBeta, serverPane: isBeta)
    }

    public static func applyingUITestOverride(_ flags: FeatureFlags, environment: [String: String]) -> FeatureFlags {
        guard environment[uiTestEnvironmentVar] != nil,
              environment[uiTestForceServerPaneOffVar] == "1" else { return flags }
        var result = flags
        result.serverPane = false
        return result
    }
}
