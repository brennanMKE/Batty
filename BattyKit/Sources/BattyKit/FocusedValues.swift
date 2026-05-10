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

private struct EnvironmentAppStateStoreKey: EnvironmentKey {
    static let defaultValue: AppStateStore? = nil
}

extension EnvironmentValues {
    public var appStateStore: AppStateStore? {
        get { self[EnvironmentAppStateStoreKey.self] }
        set { self[EnvironmentAppStateStoreKey.self] = newValue }
    }
}
