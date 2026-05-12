// BattyShortcuts.swift

import AppKit
import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "BattyShortcuts")

/// App-level keyboard shortcut router. Installed as an NSEvent local monitor
/// from `BattyAppDelegate` so Cmd-key shortcuts fire regardless of which view
/// holds first responder. Bypasses SwiftUI Commands + NSWindow's default
/// `performClose:` etc., which compete unpredictably with the terminal NSView.
@MainActor
public enum BattyShortcuts {
    /// Returns true when the event was consumed.
    public static func handle(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""

        let store = WorkspaceManager.shared.store

        switch (mods, chars) {
        case ([.command], "n"):
            logger.info("Cmd-N -> addSession")
            store.addSession()
            return true

        case ([.command], "w"):
            logger.info("Cmd-W -> closeFocusedTab")
            store.closeFocusedTab()
            return true

        case ([.command], "t"):
            logger.info("Cmd-T -> addTab")
            store.selectedSession?.focusedPane.addTab(
                inheritingCWDFrom: store.selectedSession?.focusedPane.activeTab
            )
            return true

        case ([.command], "d"):
            logger.info("Cmd-D -> split horizontal")
            if let tree = store.selectedSession?.tree {
                tree.splitFocusedPane(direction: .horizontal, inheritingFrom: tree.focusedPane)
            }
            return true

        case ([.command, .shift], "d"), ([.command, .shift], "D"):
            logger.info("Cmd-Shift-D -> split vertical")
            if let tree = store.selectedSession?.tree {
                tree.splitFocusedPane(direction: .vertical, inheritingFrom: tree.focusedPane)
            }
            return true

        case ([.command, .option], _) where event.keyCode == 123:  // left arrow
            store.selectedSession?.focusPane(adjacent: .left)
            return true

        case ([.command, .option], _) where event.keyCode == 124:  // right arrow
            store.selectedSession?.focusPane(adjacent: .right)
            return true

        case ([.command, .option], _) where event.keyCode == 126:  // up arrow
            store.selectedSession?.focusPane(adjacent: .up)
            return true

        case ([.command, .option], _) where event.keyCode == 125:  // down arrow
            store.selectedSession?.focusPane(adjacent: .down)
            return true

        case ([.command, .shift], "n"), ([.command, .shift], "N"):
            NotificationCenter.default.post(name: .battyToggleBellFeed, object: nil)
            return true

        case ([.command, .shift], "["), ([.command, .shift], "{"):
            store.selectedSession?.focusedPane.selectPreviousTab()
            return true

        case ([.command, .shift], "]"), ([.command, .shift], "}"):
            store.selectedSession?.focusedPane.selectNextTab()
            return true

        case ([.command], let digit) where digit.count == 1 && digit.first?.isWholeNumber == true:
            if let index = Int(digit), (1...9).contains(index) {
                store.selectedSession?.focusedPane.selectTab(at: index - 1)
                return true
            }
            return false

        case ([.command, .option], let digit) where digit.count == 1 && digit.first?.isWholeNumber == true:
            if let index = Int(digit), (1...9).contains(index) {
                store.selectSession(at: index - 1)
                return true
            }
            return false

        default:
            return false
        }
    }
}
