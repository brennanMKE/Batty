// BackgroundImagesWindowController.swift

import AppKit
import SwiftUI

/// Owns the Background Images `NSWindow`. Created only on demand, not a SwiftUI
/// `Window` scene: a declared scene always exists, and `BattyCommands` does not
/// replace the Window menu's list, so a scene would list it there while closed.
///
/// The window is process-global, like Settings and Help. It is never registered
/// with `AppStateStore.registerNSWindow`, so `BattyShortcuts` treats it as a
/// non-content window and Cmd-W closes it through `closeAuxiliaryWindow`. It
/// holds nothing unsaved, so closing never asks and never holds up a quit.
@MainActor
final class BackgroundImagesWindowController: NSObject, NSWindowDelegate {
    static let shared = BackgroundImagesWindowController()
    static let windowIdentifier = "background-images"

    private(set) var window: NSWindow?
    private var model: BackgroundImagesModel?
    private var scrollMonitor: BackgroundImagesScrollMonitor?
    /// The latest key-event catalog check; tests await it.
    private(set) var appearCheck: Task<Void, Never>?

    /// Builds the window without ordering it front, or returns the existing one.
    @discardableResult
    func prepare(store: AppStateStore) -> NSWindow {
        if let window { return window }
        let model = store.backgroundImages
        self.model = model
        let hosting = NSHostingController(rootView: BackgroundImagesView(model: model, mode: .manage))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = String(localized: "Background Images", comment: "Background Images window title")
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        window.setContentSize(NSSize(width: 760, height: 560))
        window.contentMinSize = NSSize(width: 520, height: 400)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.center()
        self.window = window
        BackgroundImagesDiagnostics.shared.tab = "My Images"
        scrollMonitor = BackgroundImagesScrollMonitor(window: window)
        return window
    }

    func show(store: AppStateStore) {
        let window = prepare(store: store)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// A use can change in another window while this one stays open. Its only
    /// observers are the cells' uses lines, which write nothing back. Catalogs
    /// due a check are checked too; the model throttles and merges checks.
    func windowDidBecomeKey(_ notification: Notification) {
        guard let model else { return }
        BackgroundImagesDiagnostics.shared.record("window became key")
        model.refreshUses()
        let hosted = model.hosted
        appearCheck = Task { await hosted.windowBecameKey() }
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
        scrollMonitor?.stop()
        scrollMonitor = nil
        model = nil
        appearCheck = nil
    }
}
