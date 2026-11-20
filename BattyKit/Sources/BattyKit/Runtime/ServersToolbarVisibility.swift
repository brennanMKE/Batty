// ServersToolbarVisibility.swift

import Foundation

/// When the toolbar shows the Servers button: only while a server runs, or
/// when the user asked to always show it.
public enum ServersToolbarVisibility {
    public static func isVisible(flagOn: Bool, activeCount: Int, alwaysShow: Bool) -> Bool {
        flagOn && (activeCount > 0 || alwaysShow)
    }
}
