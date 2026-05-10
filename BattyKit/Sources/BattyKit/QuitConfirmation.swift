// QuitConfirmation.swift

import AppKit
import Foundation

@MainActor
public enum QuitConfirmation {
    public static func shouldQuitOrPrompt(store: AppStateStore?) -> Bool {
        guard SettingsPreference.resolvedConfirmQuit() else { return true }
        guard let store else { return true }
        let openTabs = store.sessions.reduce(0) { acc, session in
            acc + session.tree.allPanes.reduce(0) { $0 + $1.tabs.count }
        }
        guard openTabs > 0 else { return true }

        let alert = NSAlert()
        alert.messageText = "Quit Batty?"
        alert.informativeText = openTabs == 1
            ? "There is 1 open terminal."
            : "There are \(openTabs) open terminals."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }
}
