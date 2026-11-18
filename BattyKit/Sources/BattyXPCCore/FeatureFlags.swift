// FeatureFlags.swift

import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "FeatureFlags")

/// One `Bool` per unfinished feature: on in Batty Beta, off in Prod, with no
/// other way to set it. See `docs/feature-flags.md`.
public nonisolated struct FeatureFlags: Sendable, Equatable {
    public var sharedProjectImages: Bool
    public var agentIntegration: Bool

    public init(sharedProjectImages: Bool, agentIntegration: Bool) {
        self.sharedProjectImages = sharedProjectImages
        self.agentIntegration = agentIntegration
    }

    /// For the bare `batty` Mach-O, which has no `Info.plist` to resolve a
    /// variant from at runtime: derived from the variant baked in at compile
    /// time (`ServiceNames.current`). The app never reads this; it uses
    /// `resolved(bundleIdentifier:)`.
    public static var current: FeatureFlags {
        let beta = ServiceNames.current == .beta
        return FeatureFlags(sharedProjectImages: beta, agentIntegration: beta)
    }

    /// A nil or unknown identifier fails closed.
    public static func resolved(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> FeatureFlags {
        guard let variant = ServiceNames.Variant(bundleIdentifier: bundleIdentifier) else {
            logger.error("feature flags off: bundle identifier \(bundleIdentifier ?? "<nil>", privacy: .public) is no known Batty variant")
            return FeatureFlags(sharedProjectImages: false, agentIntegration: false)
        }
        return FeatureFlags(sharedProjectImages: variant == .beta, agentIntegration: variant == .beta)
    }
}
