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

        CommandMenu("Tab") {
            Button("New Tab") {
                store?.selectedSession?.pane.addTab()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(focusedPane == nil)

            Button("Close Tab") {
                store?.selectedSession?.pane.closeActiveTab()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled((focusedPane?.tabs.count ?? 0) < 2)

            Divider()

            Button("Show Previous Tab") {
                store?.selectedSession?.pane.selectPreviousTab()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled((focusedPane?.tabs.count ?? 0) < 2)

            Button("Show Next Tab") {
                store?.selectedSession?.pane.selectNextTab()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled((focusedPane?.tabs.count ?? 0) < 2)

            Divider()

            ForEach(0..<9) { index in
                Button(tabMenuTitle(at: index)) {
                    store?.selectedSession?.pane.selectTab(at: index)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .disabled(!tabExists(at: index))
            }
        }
    }

    private var focusedPane: PaneRuntime? {
        store?.selectedSession?.pane
    }

    private func sessionMenuTitle(at index: Int) -> String {
        guard let store, store.sessions.indices.contains(index) else {
            return "Session \(index + 1)"
        }
        return store.sessions[index].title
    }

    private func sessionExists(at index: Int) -> Bool {
        guard let store else { return false }
        return store.sessions.indices.contains(index)
    }

    private func tabMenuTitle(at index: Int) -> String {
        guard let pane = focusedPane, pane.tabs.indices.contains(index) else {
            return "Tab \(index + 1)"
        }
        let tab = pane.tabs[index]
        if let override = tab.titleOverride, !override.isEmpty { return override }
        let live = tab.terminal.title
        return live.isEmpty ? "Tab \(index + 1)" : live
    }

    private func tabExists(at index: Int) -> Bool {
        focusedPane?.tabs.indices.contains(index) ?? false
    }
}
