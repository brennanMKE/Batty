// AppWideBackgroundGate+Testing.swift

import Foundation
@testable import BattyKit

extension AppWideBackgroundGate {
    /// For tests about config lines, whose fixture paths aren't real imports.
    /// `AppWideBackgroundGateTests` covers the real inspection.
    static func acceptingEveryImage(defaults: UserDefaults) -> AppWideBackgroundGate {
        AppWideBackgroundGate(defaults: defaults, isEnabled: true, inspectImage: { _ in .usable })
    }
}
