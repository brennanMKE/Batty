// ServerPanePlacementTests.swift

import Foundation
import Testing
@testable import BattyKit

struct ServerPanePlacementTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "ServerPanePlacementTests-\(UUID().uuidString)")!
    }

    @Test func serverPanePlacementDefaultsToRight() {
        #expect(ServerPanePlacement.resolved(defaults: defaults()) == .right)
        #expect(ServerPanePlacement.right.direction == .horizontal)
        #expect(ServerPanePlacement.below.direction == .vertical)
    }

    @Test func unknownStoredValueFallsBackToRight() {
        let defaults = defaults()
        defaults.set("sideways", forKey: SettingsPreference.serverPanePlacementKey)
        #expect(ServerPanePlacement.resolved(defaults: defaults) == .right)
        defaults.set("below", forKey: SettingsPreference.serverPanePlacementKey)
        #expect(ServerPanePlacement.resolved(defaults: defaults) == .below)
    }
}
