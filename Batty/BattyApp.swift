// BattyApp.swift

import AppKit
import BattyKit
import SwiftUI

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
    private var allSessionsClosedObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            BattyShortcuts.handle(event) ? nil : event
        }
        TerminalClickFocusMonitor.start()
        allSessionsClosedObserver = NotificationCenter.default.addObserver(
            forName: .battyAllSessionsClosed,
            object: nil,
            queue: .main
        ) { _ in
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if QuitConfirmation.shouldQuitOrPrompt(store: AppStateStore.shared) {
            AppStateStore.shared.nameCache.save()
            return .terminateNow
        }
        return .terminateCancel
    }
}
