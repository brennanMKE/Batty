// BattyCommands.swift

import AppKit
import SwiftUI

public struct BattyCommands: Commands {
    @FocusedValue(\.appStateStore) private var store: AppStateStore?
    @AppStorage(SidebarPreference.hiddenKey) private var sidebarHidden: Bool = false
    @AppStorage(ThemePreference.defaultsKey) private var activeThemeName: String = ""

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

        CommandMenu("Theme") {
            ForEach(GhosttyThemeCatalog.allThemes, id: \.id) { theme in
                Button {
                    selectTheme(theme)
                } label: {
                    if theme.name == activeThemeName {
                        Label(theme.name, systemImage: "checkmark")
                    } else {
                        Text(theme.name)
                    }
                }
                .disabled(store == nil)
            }
        }

        CommandGroup(replacing: .appInfo) {
            Button("About Batty") {
                AboutPanel.show()
            }
            Divider()
            Button("Check for Updates…") {
                UpdaterController.shared.checkForUpdates()
            }
            .disabled(!UpdaterController.shared.isConfigured)
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Paste") {
                PasteDispatcher.handlePasteRequest(store: store)
            }
            .keyboardShortcut("v", modifiers: .command)

            Button("Copy") {
                NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("c", modifiers: .command)

            Button("Cut") {
                NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("x", modifiers: .command)

            Button("Select All") {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("a", modifiers: .command)
        }

        CommandGroup(after: .windowArrangement) {
            Button("Toggle Bell Feed") {
                NotificationCenter.default.post(name: .battyToggleBellFeed, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(store == nil)

            Button("Mark All Bells Seen") {
                store?.markAllBellsSeen()
            }
            .disabled((store?.bellFeed.unseenCount ?? 0) == 0)
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

            Divider()

            Button("Focus Pane Left") {
                store?.selectedSession?.focusPane(adjacent: .left)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(!canFocusAdjacentPane)

            Button("Focus Pane Right") {
                store?.selectedSession?.focusPane(adjacent: .right)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(!canFocusAdjacentPane)

            Button("Focus Pane Above") {
                store?.selectedSession?.focusPane(adjacent: .up)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            .disabled(!canFocusAdjacentPane)

            Button("Focus Pane Below") {
                store?.selectedSession?.focusPane(adjacent: .down)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(!canFocusAdjacentPane)
        }

        CommandMenu("Tab") {
            Button("New Tab") {
                store?.selectedSession?.focusedPane.addTab()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(focusedPane == nil)

            Button("Close Tab") {
                store?.closeFocusedTab()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(store?.selectedSession == nil)

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

    private var canFocusAdjacentPane: Bool {
        guard let session = store?.selectedSession else { return false }
        return session.tree.allPanes.count > 1
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
        if !live.isEmpty { return live }
        if let cwd = tab.terminal.workingDirectory, !cwd.isEmpty {
            let basename = URL(fileURLWithPath: cwd).lastPathComponent
            if !basename.isEmpty, basename != "/" { return basename }
        }
        return "Tab \(index + 1)"
    }

    private func tabExists(at index: Int) -> Bool {
        focusedPane?.tabs.indices.contains(index) ?? false
    }

    private func selectTheme(_ theme: GhosttyThemeDefinition) {
        activeThemeName = theme.name
        store?.applyThemeToAllSurfaces(theme)
    }
}
