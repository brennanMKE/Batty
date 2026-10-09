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
        // `store` must be resolved before the setting can be read, since the
        // setting comes from `store.preferences`, not `.standard` — a nil
        // store falls through to `true` either way, matching the fallback
        // below for a store with no open tabs.
        guard let store else { return true }
        guard SettingsPreference.resolvedConfirmQuit(defaults: store.preferences) else { return true }
        let openTabs = openTerminalTabCount(store: store)
        guard openTabs > 0 else { return true }

        let alert = NSAlert()
        alert.messageText = String(localized: "Quit Batty?")
        alert.informativeText = String(localized: "There \(openTabs) open terminal(s).")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The count `shouldQuitOrPrompt` shows the user ("There are N open
    /// terminal(s)"). Extracted so the counting logic is unit-testable
    /// without triggering the modal `NSAlert` above.
    ///
    /// Walks all windows' sessions so a Cmd-Q with running processes in any
    /// window triggers the confirmation (#0239: widened from windows[0]).
    /// Only `.terminal`-kind panes count: a non-terminal pane's one
    /// `TabRuntime` is a structural placeholder with no live Terminal
    /// Session behind it (`PaneRuntime.kind`'s doc comment) — counting it
    /// here would inflate this user-facing prompt with panes that were
    /// never terminals (#0315 review round 1, finding 3).
    static func openTerminalTabCount(store: AppStateStore) -> Int {
        store.windows.reduce(0) { windowAcc, window in
            windowAcc + window.sessions.reduce(0) { sessionAcc, session in
                sessionAcc + session.tree.allPanes.reduce(0) { paneAcc, pane in
                    paneAcc + (pane.kind == .terminal ? pane.tabs.count : 0)
                }
            }
        }
    }

    /// Whether any tab across all windows of `store` has a running process
    /// that needs confirmation before close. Used by the window-close path
    /// to decide whether to prompt before tearing down a single window.
    /// `defaults` should be the owning `WindowDelegate`'s store's
    /// `preferences` — `RootWindowView.swift` passes it explicitly rather
    /// than through a zero-arg, `.standard`-only overload, so a test can't
    /// reach this without deciding what source it means (#0426).
    static func windowNeedsConfirmClose(window: WindowRuntime, defaults: UserDefaults) -> Bool {
        if isInUITestMode { return false }
        guard SettingsPreference.resolvedConfirmQuit(defaults: defaults) else { return false }
        return window.sessions.contains { session in
            session.tree.allPanes.contains { pane in
                pane.kind == .terminal && pane.tabs.contains { $0.needsConfirmClose }
            }
        }
    }
}
