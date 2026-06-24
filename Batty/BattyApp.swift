// BattyApp.swift

import AppKit
import BattyKit
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "co.sstools.Batty", category: "BattyApp")

@main
struct BattyApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: BattyAppDelegate

    var body: some Scene {
        WindowGroup(for: WindowID.self) { $windowID in
            ContentView(windowID: windowID ?? AppStateStore.shared.initialWindowID)
                .background(OpenWindowHookInstaller())
        } defaultValue: {
            // Return the WindowID already seeded in AppStateStore.shared.windows[0]
            // so that SwiftUI's first content window reuses the existing runtime
            // rather than creating a phantom second one. A phantom second runtime
            // causes batty <path> sessions to land in windows[0] (the phantom)
            // while the visible window shows an empty windows[1] — #0251.
            AppStateStore.shared.initialWindowID
        }
        .commandsRemoved()
        .commands {
            BattyCommands()
        }

        Window("Batty Help", id: "help") {
            HelpView()
        }

        Settings {
            SettingsView()
                .environment(\.appStateStore, AppStateStore.shared)
        }
    }
}

final class BattyAppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?
    private var appearanceObserver: AppearanceObserver?

    func applicationDidFinishLaunching(_ notification: Notification) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            BattyShortcuts.handle(event) ? nil : event
        }
        TerminalClickFocusMonitor.start()
        appearanceObserver = AppearanceObserver(store: AppStateStore.shared)
        AppStateStore.shared.nameSuggester = FoundationModelsNameSuggester.makeIfAvailable()
        AppStateStore.shared.notificationSummarizer = FoundationModelsNotificationSummarizer.makeIfAvailable()
        // onAllSessionsClosed is wired per-window in AppStateStore.init and
        // windowRuntime(for:) — each window's closure closes itself when its
        // last session goes. The app terminates when the last content window
        // is unregistered (AppStateStore.unregisterNSWindow →
        // terminateIfLastContentWindowGone). No app-level terminate hook here.
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "batty" {
            BattyURLHandler.handle(url, store: AppStateStore.shared)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let store = AppStateStore.shared
        let totalTabs = store.windows.reduce(0) { acc, w in
            acc + w.sessions.flatMap { $0.tree.allPanes }.flatMap { $0.tabs }.count
        }
        logger.info("applicationShouldTerminate windows=\(store.windows.count, privacy: .public) totalTabs=\(totalTabs, privacy: .public)")
        if QuitConfirmation.shouldQuitOrPrompt(store: store) {
            store.nameCache.save()
            logger.info("applicationShouldTerminate -> terminateNow")
            return .terminateNow
        }
        logger.info("applicationShouldTerminate -> terminateCancel (prompt shown)")
        return .terminateCancel
    }
}

/// Wires the SwiftUI `openWindow` action into `AppStateStore` so the
/// NSEvent-monitor path (`BattyShortcuts`) can open new windows without an
/// `@Environment` reference. Placed in the content scene's view tree so the
/// action is always live while any content window exists.
private struct OpenWindowHookInstaller: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .onAppear {
                AppStateStore.shared.openWindowAction = {
                    logger.info("openWindowAction: opening new content window")
                    openWindow(value: WindowID())
                }
            }
    }
}
