// BattyApp.swift

import BattyKit
import SwiftUI

@main
struct BattyApp: App {
    var body: some Scene {
        WindowGroup {
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
