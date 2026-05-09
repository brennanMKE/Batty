// BattyCommands.swift

import SwiftUI

public struct BattyCommands: Commands {
    @FocusedValue(\.appStateStore) private var store: AppStateStore?
    @AppStorage(SidebarPreference.hiddenKey) private var sidebarHidden: Bool = false

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(sidebarHidden ? "Show Sidebar" : "Hide Sidebar") {
                sidebarHidden.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
        }

        CommandMenu("Session") {
            Button("New Session") {
                store?.addSession()
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(store == nil)

            Divider()

            ForEach(0..<9) { index in
                Button(sessionMenuTitle(at: index)) {
                    store?.selectSession(at: index)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                .disabled(!sessionExists(at: index))
            }
        }
    }

    private func sessionMenuTitle(at index: Int) -> String {
        guard let store, store.sessions.indices.contains(index) else {
            return "Session \(index + 1)"
        }
        let session = store.sessions[index]
        let live = session.terminal.title
        return live.isEmpty ? session.title : live
    }

    private func sessionExists(at index: Int) -> Bool {
        guard let store else { return false }
        return store.sessions.indices.contains(index)
    }
}
