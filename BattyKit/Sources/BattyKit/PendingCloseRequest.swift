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
    }

    public var title: String {
        switch kind {
        case .singleTab: return "Close tab?"
        case .otherTabs: return "Close other tabs?"
        }
    }
}
