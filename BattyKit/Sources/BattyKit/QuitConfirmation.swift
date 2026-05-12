// QuitConfirmation.swift

import AppKit
import Foundation

@MainActor
public enum QuitConfirmation {
    /// Environment variable set by BattyUITests to bypass the modal
    /// quit-confirmation alert. xcodebuild test's teardown sends
    /// terminate() to the app and can't dismiss a modal prompt, so
    /// without this bypass the run hangs on "Failed to terminate
    /// co.sstools.Batty" and pollutes CI output.
    public static let testModeEnvVar = "BATTY_UI_TEST_MODE"

    public static var isInUITestMode: Bool {
        ProcessInfo.processInfo.environment[testModeEnvVar] == "1"
    }

    public static func shouldQuitOrPrompt(store: AppStateStore?) -> Bool {
        if isInUITestMode { return true }
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
