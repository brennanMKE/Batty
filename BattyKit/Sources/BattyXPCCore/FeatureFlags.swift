// FeatureFlags.swift

import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "FeatureFlags")

/// One `Bool` per unfinished feature: on in Batty Beta, off in Prod, with no
/// other way to set it. See `docs/feature-flags.md`.
public nonisolated struct FeatureFlags: Sendable, Equatable {
    public var sharedProjectImages: Bool
    public var servers: Bool
    public var compactSidebar: Bool

    public init(sharedProjectImages: Bool, servers: Bool = false, compactSidebar: Bool = false) {
        self.sharedProjectImages = sharedProjectImages
        self.servers = servers
        self.compactSidebar = compactSidebar
    }

    /// Present in the environment only for UI-test runs; the same variable
    /// `UITestDriver.scriptEnvVar` names.
    public static let uiTestEnvironmentVar = "BATTY_UI_TEST_SCRIPT"

    /// When "1" alongside `uiTestEnvironmentVar`, forces `servers` off. It
    /// can never force a flag on.
    public static let uiTestForceServersOffVar = "BATTY_UI_TEST_FORCE_SERVERS_OFF"

    /// When "1" alongside `uiTestEnvironmentVar`, forces `compactSidebar` off.
    public static let uiTestForceCompactSidebarOffVar = "BATTY_UI_TEST_FORCE_COMPACT_SIDEBAR_OFF"

    /// A nil or unknown identifier fails closed.
    public static func resolved(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> FeatureFlags {
        guard let variant = ServiceNames.Variant(bundleIdentifier: bundleIdentifier) else {
            logger.error("feature flags off: bundle identifier \(bundleIdentifier ?? "<nil>", privacy: .public) is no known Batty variant")
            return FeatureFlags(sharedProjectImages: false, servers: false)
        }
        let isBeta = variant == .beta
        return applyingUITestOverride(
            FeatureFlags(sharedProjectImages: isBeta, servers: isBeta, compactSidebar: isBeta),
            environment: environment
        )
    }

    /// For the `batty` CLI, a bare Mach-O with no `Info.plist`: derived from
    /// the compile-time `ServiceNames.current`. Always off under `swift test`,
    /// so code branching on it takes the flags as a parameter. The app never
    /// reads this; it uses `resolved(bundleIdentifier:)`.
    public static var current: FeatureFlags {
        let isBeta = ServiceNames.current == .beta
        return FeatureFlags(sharedProjectImages: isBeta, servers: isBeta, compactSidebar: isBeta)
    }

    public static func applyingUITestOverride(_ flags: FeatureFlags, environment: [String: String]) -> FeatureFlags {
        guard environment[uiTestEnvironmentVar] != nil else { return flags }
        var result = flags
        if environment[uiTestForceServersOffVar] == "1" { result.servers = false }
        if environment[uiTestForceCompactSidebarOffVar] == "1" { result.compactSidebar = false }
        return result
    }
}
