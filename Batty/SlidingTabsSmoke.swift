// SlidingTabsSmoke.swift

import BattyKit
import SwiftUI

@MainActor
private enum SlidingTabsSmoke {
    private struct Item: Identifiable {
        let id: UUID
    }

    static let bar: any Any.Type = SlidingTabBar<Item, DefaultTabChip>.self
    static let chip: any Any.Type = DefaultTabChip.self
}
