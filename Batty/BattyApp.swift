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
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if QuitConfirmation.shouldQuitOrPrompt(store: WorkspaceManager.shared.store) {
            return .terminateNow
        }
        return .terminateCancel
    }
}
