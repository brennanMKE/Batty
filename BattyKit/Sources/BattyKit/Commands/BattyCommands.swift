// BattyCommands.swift

import AppKit
import OSLog
import SwiftUI

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "BattyCommands")

public struct BattyCommands: Commands {
    @AppStorage(SidebarPreference.hiddenKey) private var sidebarHidden: Bool = false
    @AppStorage(ThemePreference.defaultsKey) private var activeThemeName: String = ""

    private var store: AppStateStore { WorkspaceManager.shared.store }
    private var shortcuts: ShortcutsStore { ShortcutsStore.shared }

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") {
                logger.info("Cmd-N action fired (File → New Session)")
                store.addSession()
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .newSession))
        }

        CommandGroup(after: .sidebar) {
            Button(sidebarHidden
                ? String(localized: "Show Sidebar")
                : String(localized: "Hide Sidebar")) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    sidebarHidden.toggle()
                }
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .toggleSidebar))
        }

        CommandMenu("Session") {
            Button("New Session") {
                store.addSession()
            }

            Divider()

            ForEach(0..<9) { index in
                Button {
                    store.selectSession(at: index)
                } label: {
                    Text(sessionMenuTitle(at: index))
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
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .toggleBellFeed))

            Button("Mark All Bells Seen") {
                store.markAllBellsSeen()
            }
            .disabled(store.bellFeed.unseenCount == 0)
        }

        CommandGroup(replacing: .help) {
            BattyHelpMenuButton()
        }

        CommandMenu("Pane") {
            Button("Split Horizontally") {
                guard let tree = store.selectedSession?.tree else { return }
                tree.splitFocusedPane(direction: .horizontal, inheritingFrom: tree.focusedPane)
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .splitHorizontal))
            .disabled(store.selectedSession == nil)

            Button("Split Vertically") {
                guard let tree = store.selectedSession?.tree else { return }
                tree.splitFocusedPane(direction: .vertical, inheritingFrom: tree.focusedPane)
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .splitVertical))
            .disabled(store.selectedSession == nil)

            Divider()

            Button("Focus Pane Left") {
                store.selectedSession?.focusPane(adjacent: .left)
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .focusPaneLeft))
            .disabled(!canFocusAdjacentPane)

            Button("Focus Pane Right") {
                store.selectedSession?.focusPane(adjacent: .right)
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .focusPaneRight))
            .disabled(!canFocusAdjacentPane)

            Button("Focus Pane Above") {
                store.selectedSession?.focusPane(adjacent: .up)
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .focusPaneUp))
            .disabled(!canFocusAdjacentPane)

            Button("Focus Pane Below") {
                store.selectedSession?.focusPane(adjacent: .down)
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .focusPaneDown))
            .disabled(!canFocusAdjacentPane)
        }

        CommandMenu("Tab") {
            Button("New Tab") {
                store.selectedSession?.focusedPane.addTab()
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .newTab))
            .disabled(focusedPane == nil)

            Button("Close Tab") {
                logger.info("Cmd-W action fired (Tab → Close Tab)")
                store.requestCloseFocusedTab()
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .closeTab))
            .disabled(store.selectedSession == nil)

            Divider()

            Button("Show Previous Tab") {
                store.selectedSession?.focusedPane.selectPreviousTab()
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .previousTab))
            .disabled((focusedPane?.tabs.count ?? 0) < 2)

            Button("Show Next Tab") {
                store.selectedSession?.focusedPane.selectNextTab()
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .nextTab))
            .disabled((focusedPane?.tabs.count ?? 0) < 2)

            Divider()

            ForEach(0..<9) { index in
                Button {
                    store.selectedSession?.focusedPane.selectTab(at: index)
                } label: {
                    Text(tabMenuTitle(at: index))
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .disabled(!tabExists(at: index))
            }
        }
    }

    private var focusedPane: PaneRuntime? {
        store.selectedSession?.focusedPane
    }

    private var canFocusAdjacentPane: Bool {
        guard let session = store.selectedSession else { return false }
        return session.tree.allPanes.count > 1
    }

    private func sessionMenuTitle(at index: Int) -> String {
        guard store.sessions.indices.contains(index) else {
            return String(localized: "Session \(index + 1)")
        }
        return store.sessions[index].title
    }

    private func sessionExists(at index: Int) -> Bool {
        store.sessions.indices.contains(index)
    }

    private func tabMenuTitle(at index: Int) -> String {
        let fallback = String(localized: "Tab \(index + 1)")
        guard let pane = focusedPane, pane.tabs.indices.contains(index) else {
            return fallback
        }
        return TabTitleFormatter.chipTitle(for: pane.tabs[index], fallback: fallback)
    }

    private func tabExists(at index: Int) -> Bool {
        focusedPane?.tabs.indices.contains(index) ?? false
    }

    private func selectTheme(_ theme: GhosttyThemeDefinition) {
        activeThemeName = theme.name
        store.applyThemeToAllSurfaces(theme)
    }
}

private struct BattyHelpMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Batty Help") {
            openWindow(id: "help")
        }
        .keyboardShortcut("?", modifiers: .command)
    }
}
