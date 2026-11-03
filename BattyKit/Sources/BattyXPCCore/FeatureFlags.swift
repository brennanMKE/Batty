// FeatureFlags.swift

import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "FeatureFlags")

/// Release-gating flags. Policy, not preference: a flag is on in Batty Beta
/// and off in Prod, derived from the variant alone. Nothing reads
/// `UserDefaults` and nothing can turn a flag on in Prod. See
/// `docs/feature-flags.md`.
public nonisolated struct FeatureFlags: Sendable, Equatable {
    public var terminalBackgrounds: Bool

    public init(terminalBackgrounds: Bool) {
        self.terminalBackgrounds = terminalBackgrounds
    }

    /// Present in the environment only for UI-test runs; the same variable
    /// `UITestDriver.scriptEnvVar` names.
    public static let uiTestEnvironmentVar = "BATTY_UI_TEST_SCRIPT"

    /// When set to "1" alongside `uiTestEnvironmentVar`, forces
    /// `terminalBackgrounds` off. It can never force a flag on.
    public static let uiTestForceBackgroundsOffVar = "BATTY_UI_TEST_FORCE_BACKGROUNDS_OFF"

    /// From the bundle identifier at runtime. Nil or unknown identifiers fail
    /// closed to off.
    public static func resolved(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> FeatureFlags {
        guard let variant = ServiceNames.Variant(bundleIdentifier: bundleIdentifier) else {
            logger.error("unrecognized bundle identifier \(bundleIdentifier ?? "nil", privacy: .public); feature flags off")
            return FeatureFlags(terminalBackgrounds: false)
        }
        return applyingUITestOverride(FeatureFlags(terminalBackgrounds: variant == .beta), environment: environment)
    }

    static func applyingUITestOverride(_ flags: FeatureFlags, environment: [String: String]) -> FeatureFlags {
        guard environment[uiTestEnvironmentVar] != nil,
              environment[uiTestForceBackgroundsOffVar] == "1" else { return flags }
        var result = flags
        result.terminalBackgrounds = false
        return result
    }
}
