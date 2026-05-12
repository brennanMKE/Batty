// BattyApp.swift

import AppKit
import BattyKit
import SwiftUI

@main
struct BattyApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: BattyAppDelegate

    var body: some Scene {
        Window("Batty", id: "main") {
            ContentView()
        }
        .commandsRemoved()
        .commands {
            BattyCommands()
        }

        Settings {
            SettingsView()
                .environment(\.appStateStore, WorkspaceManager.shared.store)
        }
    }
}

final class BattyAppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            BattyShortcuts.handle(event) ? nil : event
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if QuitConfirmation.shouldQuitOrPrompt(store: WorkspaceManager.shared.store) {
            return .terminateNow
        }
        return .terminateCancel
    }
}
