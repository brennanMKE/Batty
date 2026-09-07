// PendingCloseRequest.swift

import Foundation

/// Captured at the moment the user requests a close that needs
/// confirmation. The view layer presents the dialog; the store
/// commits the close when the user confirms.
public struct PendingCloseRequest: Identifiable, Equatable {
    public let id = UUID()
    public let kind: Kind
    public let message: String

    public enum Kind: Equatable {
        /// Close a single tab.
        case singleTab(tabID: UUID)
        /// Close every tab in `paneID` except `keepingTabID`.
        case otherTabs(paneID: UUID, keepingTabID: UUID)
        /// Close every Tab across every Pane in `sessionID` and remove the
        /// Session itself (#0396) — the Sidebar's "Close" control routed
        /// through the same confirmation gate `singleTab`/`otherTabs` use.
        case session(sessionID: UUID)
    }

    public var title: String {
        switch kind {
        case .singleTab: return String(localized: "Close tab?")
        case .otherTabs: return String(localized: "Close other tabs?")
        case .session: return String(localized: "Close session?")
        }
    }
}
