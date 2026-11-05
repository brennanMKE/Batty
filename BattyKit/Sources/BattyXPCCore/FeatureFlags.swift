// FeatureFlags.swift

import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "FeatureFlags")

/// One `Bool` per unfinished feature: on in Batty Beta, off in Prod, with no
/// other way to set it. See `docs/feature-flags.md`.
public nonisolated struct FeatureFlags: Sendable, Equatable {
    public var sharedProjectImages: Bool

    public init(sharedProjectImages: Bool) {
        self.sharedProjectImages = sharedProjectImages
    }

    /// A nil or unknown identifier fails closed.
    public static func resolved(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> FeatureFlags {
        guard let variant = ServiceNames.Variant(bundleIdentifier: bundleIdentifier) else {
            logger.error("feature flags off: bundle identifier \(bundleIdentifier ?? "<nil>", privacy: .public) is no known Batty variant")
            return FeatureFlags(sharedProjectImages: false)
        }
        return FeatureFlags(sharedProjectImages: variant == .beta)
    }
}
