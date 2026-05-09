// FocusedValues.swift

import SwiftUI

private struct FocusedAppStateStoreKey: FocusedValueKey {
    typealias Value = AppStateStore
}

extension FocusedValues {
    public var appStateStore: AppStateStore? {
        get { self[FocusedAppStateStoreKey.self] }
        set { self[FocusedAppStateStoreKey.self] = newValue }
    }
}
