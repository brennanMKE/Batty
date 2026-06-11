// BattyApp.swift

import AppKit
import BattyKit
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "co.sstools.Batty", category: "BattyApp")

@main
struct BattyApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: BattyAppDelegate

    private let mainWindowTitle: String = "Batty"

    var body: some Scene {
        Window(mainWindowTitle, id: "main") {
            ContentView()
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            BattyShortcuts.handle(event) ? nil : event
        }
        TerminalClickFocusMonitor.start()
        AppStateStore.shared.nameSuggester = FoundationModelsNameSuggester.makeIfAvailable()
        AppStateStore.shared.onAllSessionsClosed = {
            logger.info("onAllSessionsClosed fired; terminating app")
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let store = AppStateStore.shared
        let openTabs = store.sessions.flatMap { $0.tree.allPanes }.flatMap { $0.tabs }.count
        logger.info("applicationShouldTerminate sessions=\(store.sessions.count) openTabs=\(openTabs)")
        if QuitConfirmation.shouldQuitOrPrompt(store: store) {
            store.nameCache.save()
            logger.info("applicationShouldTerminate -> terminateNow")
            return .terminateNow
        }
        logger.info("applicationShouldTerminate -> terminateCancel (prompt shown)")
        return .terminateCancel
    }
}
