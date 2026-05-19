// FocusedValues.swift

import SwiftUI

private struct EnvironmentAppStateStoreKey: EnvironmentKey {
    static let defaultValue: AppStateStore? = nil
}

private struct EnvironmentIsSelectedSessionKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    public var appStateStore: AppStateStore? {
        get { self[EnvironmentAppStateStoreKey.self] }
        set { self[EnvironmentAppStateStoreKey.self] = newValue }
    }

    /// True when the surrounding view tree belongs to the currently
    /// selected session in `AppStateStore`. Used by ``TerminalPlaceholderView``
    /// to decide whether the host should mark its tab as visible.
    public var isSelectedSession: Bool {
        get { self[EnvironmentIsSelectedSessionKey.self] }
        set { self[EnvironmentIsSelectedSessionKey.self] = newValue }
    }
}
