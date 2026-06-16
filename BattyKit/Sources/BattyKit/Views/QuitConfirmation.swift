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
        // Walk all windows' sessions so a Cmd-Q with running processes in
        // any window triggers the confirmation (#0239: widened from windows[0]).
        let openTabs = store.windows.reduce(0) { windowAcc, window in
            windowAcc + window.sessions.reduce(0) { sessionAcc, session in
                sessionAcc + session.tree.allPanes.reduce(0) { $0 + $1.tabs.count }
            }
        }
        guard openTabs > 0 else { return true }

        let alert = NSAlert()
        alert.messageText = String(localized: "Quit Batty?")
        alert.informativeText = String(localized: "There \(openTabs) open terminal(s).")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Whether any tab across all windows of `store` has a running process
    /// that needs confirmation before close. Used by the window-close path
    /// to decide whether to prompt before tearing down a single window.
    public static func windowNeedsConfirmClose(window: WindowRuntime) -> Bool {
        if isInUITestMode { return false }
        guard SettingsPreference.resolvedConfirmQuit() else { return false }
        return window.sessions.contains { session in
            session.tree.allPanes.contains { pane in
                pane.tabs.contains { $0.terminal.needsConfirmClose }
            }
        }
    }
}
