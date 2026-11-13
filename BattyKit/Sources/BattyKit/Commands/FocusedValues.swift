// FocusedValues.swift

import SwiftUI

private struct EnvironmentAppStateStoreKey: EnvironmentKey {
    static let defaultValue: AppStateStore? = nil
}

private struct EnvironmentWindowIDKey: EnvironmentKey {
    /// `nil` before the window-aware host is installed; any view that needs
    /// the `WindowID` must sit below a `SessionDetailView` in the tree.
    static let defaultValue: WindowID? = nil
}

extension EnvironmentValues {
    public var appStateStore: AppStateStore? {
        get { self[EnvironmentAppStateStoreKey.self] }
        set { self[EnvironmentAppStateStoreKey.self] = newValue }
    }

    /// The ``WindowID`` of the content window this view tree belongs to.
    /// Set once in ``SessionDetailView`` and read by ``TerminalPlaceholderView``
    /// to route terminal-view creation to the correct per-window host.
    public var windowID: WindowID? {
        get { self[EnvironmentWindowIDKey.self] }
        set { self[EnvironmentWindowIDKey.self] = newValue }
    }
}
