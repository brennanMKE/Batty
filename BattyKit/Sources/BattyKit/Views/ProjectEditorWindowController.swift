// ProjectEditorWindowController.swift

import AppKit
import BattyXPCCore
import os
import SwiftUI

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "ProjectEditorWindow")

/// Owns the Project Editor's `NSWindow`. The editor is an AppKit-managed
/// window created only on demand, not a SwiftUI `Window` scene: a declared
/// scene exists whether or not the flag is on, and `BattyCommands` does not
/// replace the Window menu's list, so a scene could show Projects in Prod.
/// With the flag off nothing here ever creates a window, a model or a
/// `ProjectStore`.
///
/// The window is process-global, like Settings and Help. It is never
/// registered with `AppStateStore.registerNSWindow`, so `BattyShortcuts`
/// treats it as a non-content window (`keyWindowIsContentWindow()`), and
/// actions it triggers resolve their target through `defaultTargetWindow()`.
@MainActor
final class ProjectEditorWindowController: NSObject, NSWindowDelegate {
    static let shared = ProjectEditorWindowController()
    static let windowIdentifier = "project-editor"

    private(set) var window: NSWindow?
    private(set) var model: ProjectEditorViewModel?
    private weak var store: AppStateStore?

    /// Whether the editor may be offered or opened at all. The File menu and
    /// `prepare` both read this.
    static func isAvailable(featureFlags: FeatureFlags) -> Bool {
        featureFlags.projects
    }

    /// Builds the window and model without ordering the window front, or
    /// reuses the existing ones. `selecting` selects that Project; `newDraft`
    /// starts an unsaved Project from the given draft (#0476's "Save as
    /// Project" supplies one). When the open editor holds unsaved changes the
    /// editor asks what to do before switching.
    @discardableResult
    func prepare(store: AppStateStore, selecting projectID: UUID? = nil, newDraft: ProjectDraft? = nil) -> Bool {
        guard Self.isAvailable(featureFlags: store.featureFlags), let projectStore = store.projectStore else {
            logger.notice("project editor: ignored; projects feature is off")
            return false
        }
        if let model, window != nil {
            if let newDraft {
                model.requestNavigation(.newDraft(newDraft))
            } else if let projectID {
                model.requestNavigation(.select(projectID))
            }
            return true
        }

        let model = ProjectEditorViewModel(
            store: projectStore,
            initialSelection: newDraft == nil ? projectID : nil,
            defaultRoot: { [weak store] in
                store?.defaultTargetWindow()?.selectedSession?.focusedTerminalPane?.activeTab?.workingDirectory
            },
            openProject: { [weak store] id in
                guard let store else { return }
                ProjectOpenPresenter.open(id: id, mode: .focusExistingOrOpen, in: store)
            },
            captureSession: { [weak store] root in
                guard let session = store?.defaultTargetWindow()?.selectedSession else { return nil }
                return SessionProjectCapture.capture(session: session, root: root)
            }
        )
        if let newDraft { model.requestNavigation(.newDraft(newDraft)) }

        let hosting = NSHostingController(rootView: ProjectEditorView(model: model))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = String(localized: "Projects", comment: "Project Editor window title")
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        window.setContentSize(NSSize(width: 1120, height: 740))
        window.contentMinSize = NSSize(width: 960, height: 620)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.center()
        model.projectSaved = { [weak store] project in store?.applyProjectSymbol(of: project) }
        model.closeWindow = { [weak self] in self?.window?.close() }
        model.presentForQuit = { [weak self] in
            guard let window = self?.window, window.attachedSheet == nil else { return false }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return true
        }
        self.store = store

        self.model = model
        self.window = window
        return true
    }

    /// `startNewProject` begins an empty unsaved Project, as the editor's own
    /// "New Project" button does, after any selection or draft.
    @discardableResult
    func show(store: AppStateStore, selecting projectID: UUID? = nil, newDraft: ProjectDraft? = nil, startNewProject: Bool = false) -> Bool {
        guard prepare(store: store, selecting: projectID, newDraft: newDraft), let window else { return false }
        if startNewProject { model?.requestNewProject() }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model, model.isDirty else { return true }
        model.requestNavigation(.closeWindow)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
        model?.abandonQuit()
        model = nil
        store?.projectEditorDidClose()
    }
}
