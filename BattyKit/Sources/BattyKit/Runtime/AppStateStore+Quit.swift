// AppStateStore+Quit.swift

import AppKit
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "AppStateStoreQuit")

extension AppStateStore {
    /// The Project Editor's view model, or nil with the Projects flag off,
    /// without ever touching `ProjectEditorWindowController.shared` then.
    func openProjectEditorModel() -> ProjectEditorViewModel? {
        guard featureFlags.projects else { return nil }
        if let projectEditorModelOverride { return projectEditorModelOverride() }
        return ProjectEditorWindowController.shared.model
    }

    /// Answers a quit request (`applicationShouldTerminate`). A dirty
    /// Project Editor asks its Save / Discard / Cancel question first; only
    /// when that lets the quit continue does `confirm`, the existing "Quit
    /// Batty?" alert, run, so an editor prompt never follows a confirmed
    /// Quit. A clean editor, no editor, the flag off, or UI-test mode
    /// without `QuitConfirmation.promptEditorOnQuitEnvVar` skip the editor
    /// question and behave as before.
    ///
    /// Returns `.terminateLater` when the editor's question is up. `reply`
    /// is then called exactly once with the final answer, when the question
    /// is answered or abandoned; the app delegate passes
    /// `NSApp.reply(toApplicationShouldTerminate:)`. For the other results
    /// `reply` is never called.
    public func handleTerminateRequest(
        promptsEditor: Bool = QuitConfirmation.promptsEditorOnQuit,
        confirm: @escaping @MainActor (AppStateStore) -> Bool = { QuitConfirmation.shouldQuitOrPrompt(store: $0) },
        reply: @escaping @MainActor (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        if promptsEditor, let editor = openProjectEditorModel(), editor.isDirty {
            var answeredImmediately: Bool?
            var deferred = false
            editor.requestQuit { [weak self] proceed in
                let outcome = proceed && (self.map(confirm) ?? true)
                if outcome { self?.nameCache.save() }
                if deferred {
                    reply(outcome)
                } else {
                    answeredImmediately = outcome
                }
            }
            if let answeredImmediately {
                return answeredImmediately ? .terminateNow : .terminateCancel
            }
            deferred = true
            logger.info("handleTerminateRequest: asking about the Project Editor's unsaved edits")
            return .terminateLater
        }
        guard confirm(self) else { return .terminateCancel }
        nameCache.save()
        return .terminateNow
    }

    /// True while the Project Editor has unsaved edits; the automatic quit
    /// then waits for the editor to close, which asks about them. A clean
    /// editor does not hold the app open: nothing would be lost.
    func holdQuitForUnsavedEditor() -> Bool {
        guard let editor = openProjectEditorModel(), editor.isDirty else { return false }
        quitWhenEditorCloses = true
        logger.info("terminateIfLastContentWindowGone: holding the quit; the Project Editor has unsaved edits")
        return true
    }

    /// The editor window has closed. Re-runs the automatic-quit check when it
    /// was holding the quit; the check itself re-reads the live window state.
    func projectEditorDidClose() {
        guard quitWhenEditorCloses else { return }
        quitWhenEditorCloses = false
        terminateIfLastContentWindowGone()
    }

    /// Close item while the Project Editor is key, or a sheet over it. Closes
    /// the editor window itself (asking first when it has unsaved edits), not
    /// the sheet. While a sheet is up the window cannot answer, so nothing
    /// happens. Returns whether `window` resolved to the editor.
    @discardableResult
    func closeProjectEditor(from window: NSWindow?, close: (NSWindow) -> Void = { $0.performClose(nil) }) -> Bool {
        guard let editor = Self.projectEditorWindow(from: window) else { return false }
        if editor === window, editor.attachedSheet == nil { close(editor) }
        return true
    }

    /// Whether the Tab menu's Close item is enabled. Disabled only for a
    /// content window with no selected Session. With no content window it
    /// stays enabled so the item can close the Project Editor. It makes the
    /// same `keyWindowOrFirstRegistered()` read the item made before, so it
    /// adds no key-window dependency, and the nil branch reads nothing
    /// observed. A stale value is benign: a stale true dates from a moment
    /// when a content window with a selected Session existed, and a stale
    /// false needs a content window with no selected Session, which is
    /// transient.
    var closeItemIsEnabled: Bool {
        guard let window = keyWindowOrFirstRegistered() else { return true }
        return window.selectedSession != nil
    }
}
