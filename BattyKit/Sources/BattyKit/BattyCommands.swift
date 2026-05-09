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

        CommandMenu("Pane") {
            Button("Split Horizontally") {
                store?.selectedSession?.tree.splitFocusedPane(direction: .horizontal)
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(store?.selectedSession == nil)

            Button("Split Vertically") {
                store?.selectedSession?.tree.splitFocusedPane(direction: .vertical)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(store?.selectedSession == nil)
        }

        CommandMenu("Tab") {
            Button("New Tab") {
                store?.selectedSession?.focusedPane.addTab()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(focusedPane == nil)

            Button("Close Tab") {
                store?.selectedSession?.focusedPane.closeActiveTab()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled((focusedPane?.tabs.count ?? 0) < 2)

            Divider()

            Button("Show Previous Tab") {
                store?.selectedSession?.focusedPane.selectPreviousTab()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled((focusedPane?.tabs.count ?? 0) < 2)

            Button("Show Next Tab") {
                store?.selectedSession?.focusedPane.selectNextTab()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled((focusedPane?.tabs.count ?? 0) < 2)

            Divider()

            ForEach(0..<9) { index in
                Button(tabMenuTitle(at: index)) {
                    store?.selectedSession?.focusedPane.selectTab(at: index)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .disabled(!tabExists(at: index))
            }
        }
    }

    private var focusedPane: PaneRuntime? {
        store?.selectedSession?.focusedPane
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
