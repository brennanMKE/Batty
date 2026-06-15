// FocusedValues.swift

import SwiftUI

private struct EnvironmentAppStateStoreKey: EnvironmentKey {
    static let defaultValue: AppStateStore? = nil
}

private struct EnvironmentIsSelectedSessionKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

private struct SplitDetailToolbarSafeInsetTopKey: EnvironmentKey {
    static let defaultValue: CGFloat = -1
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

    /// True when the surrounding view tree belongs to the currently
    /// selected session in `AppStateStore`. Used by ``TerminalPlaceholderView``
    /// to decide whether the host should mark its tab as visible.
    public var isSelectedSession: Bool {
        get { self[EnvironmentIsSelectedSessionKey.self] }
        set { self[EnvironmentIsSelectedSessionKey.self] = newValue }
    }

    /// Top edge inset beneath the unified title/toolbar in the Navigation
    /// detail column. Measured outside nested split `GeometryReader`s;
    /// `-1` means not yet populated (child views should rely on local geometry).
    public var splitDetailToolbarSafeInsetTop: CGFloat {
        get { self[SplitDetailToolbarSafeInsetTopKey.self] }
        set { self[SplitDetailToolbarSafeInsetTopKey.self] = newValue }
    }

    /// The ``WindowID`` of the content window this view tree belongs to.
    /// Set once in ``SessionDetailView`` and read by ``TerminalPlaceholderView``
    /// to route terminal-view creation to the correct per-window host.
    public var windowID: WindowID? {
        get { self[EnvironmentWindowIDKey.self] }
        set { self[EnvironmentWindowIDKey.self] = newValue }
    }
}
