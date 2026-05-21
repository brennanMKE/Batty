// BattyCommands.swift

import AppKit
import OSLog
import SwiftUI

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "BattyCommands")

public struct BattyCommands: Commands {
    @AppStorage(SidebarPreference.hiddenKey) private var sidebarHidden: Bool = false
    @AppStorage(ThemePreference.defaultsKey) private var activeThemeName: String = ""
    @AppStorage(SettingsPreference.cmdNumberTargetKey) private var cmdNumberTarget: String = SettingsPreference.defaultCmdNumberTarget

    private var store: AppStateStore { AppStateStore.shared }
    private var shortcuts: ShortcutsStore { ShortcutsStore.shared }

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") {
                logger.info("Cmd-N action fired (File → New Session)")
                store.addSession()
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .newSession))

            Divider()

            Button {
                NotificationCenter.default.post(name: .battyToggleOpenQuickly, object: nil)
            } label: {
                Label("Open Quickly\u{2026}", systemImage: "bolt")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .openQuickly))
            .disabled(store.selectedSession == nil)
        }

        CommandGroup(after: .sidebar) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    sidebarHidden.toggle()
                }
            } label: {
                Label(
                    sidebarHidden ? String(localized: "Show Sidebar") : String(localized: "Hide Sidebar"),
                    systemImage: "sidebar.left"
                )
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .toggleSidebar))
        }

        CommandMenu("Session") {
            Button {
                store.addSession()
            } label: {
                Label("New Session", systemImage: "plus.square")
            }

            Divider()

            Button {
                NotificationCenter.default.post(name: .battyToggleLayoutPicker, object: nil)
            } label: {
                Label("Choose Layout\u{2026}", systemImage: "rectangle.3.group")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .layoutPicker))
            .disabled(store.selectedSession?.tree.allPanes.count != 1)

            Divider()

            ForEach(0..<9) { index in
                Button {
                    store.selectSession(at: index)
                } label: {
                    Text(sessionMenuTitle(at: index))
                }
                .keyboardShortcut(
                    KeyEquivalent(Character("\(index + 1)")),
                    modifiers: cmdNumberSwitchesSessions ? .command : [.command, .option]
                )
                .disabled(!sessionExists(at: index))
            }
        }

        CommandMenu("Theme") {
            Button {
                NotificationCenter.default.post(name: .battyToggleThemeSelector, object: nil)
            } label: {
                Label("Open Theme Selector\u{2026}", systemImage: "paintbrush")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .themeSelector))

            Button {
                togglePinCurrentTheme()
            } label: {
                Label(
                    isPinnedCurrentTheme ? String(localized: "Unpin Theme") : String(localized: "Pin Theme"),
                    systemImage: isPinnedCurrentTheme ? "pin.slash" : "pin"
                )
            }
            .disabled(activeThemeName.isEmpty)

            Divider()

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
            Button {
                NotificationCenter.default.post(name: .battyToggleBellFeed, object: nil)
            } label: {
                Label("Toggle Bell Feed", systemImage: "bell")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .toggleBellFeed))

            Button {
                store.markAllBellsSeen()
            } label: {
                Label("Mark All Bells Seen", systemImage: "bell.slash")
            }
            .disabled(store.bellFeed.unseenCount == 0)
        }

        CommandGroup(replacing: .help) {
            BattyHelpMenuButton()
        }

        CommandMenu("Pane") {
            Button {
                guard let tree = store.selectedSession?.tree else { return }
                tree.splitFocusedPane(direction: .horizontal, inheritingFrom: tree.focusedPane)
            } label: {
                Label("Split Horizontally", systemImage: "rectangle.split.2x1")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .splitHorizontal))
            .disabled(store.selectedSession == nil)

            Button {
                guard let tree = store.selectedSession?.tree else { return }
                tree.splitFocusedPane(direction: .vertical, inheritingFrom: tree.focusedPane)
            } label: {
                Label("Split Vertically", systemImage: "rectangle.split.1x2")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .splitVertical))
            .disabled(store.selectedSession == nil)

            Button {
                NotificationCenter.default.post(name: .battyToggleLayoutPicker, object: nil)
            } label: {
                Label("Layouts\u{2026}", systemImage: "rectangle.3.group")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .layoutPicker))
            .disabled(store.selectedSession?.tree.allPanes.count != 1)

            Divider()

            Button {
                store.selectedSession?.focusPane(adjacent: .left)
            } label: {
                Label("Focus Pane Left", systemImage: "arrow.left")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .focusPaneLeft))
            .disabled(!canFocusAdjacentPane)

            Button {
                store.selectedSession?.focusPane(adjacent: .right)
            } label: {
                Label("Focus Pane Right", systemImage: "arrow.right")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .focusPaneRight))
            .disabled(!canFocusAdjacentPane)

            Button {
                store.selectedSession?.focusPane(adjacent: .up)
            } label: {
                Label("Focus Pane Above", systemImage: "arrow.up")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .focusPaneUp))
            .disabled(!canFocusAdjacentPane)

            Button {
                store.selectedSession?.focusPane(adjacent: .down)
            } label: {
                Label("Focus Pane Below", systemImage: "arrow.down")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .focusPaneDown))
            .disabled(!canFocusAdjacentPane)
        }

        CommandMenu("Tab") {
            Button {
                store.selectedSession?.focusedPane.addTab()
            } label: {
                Label("New Tab", systemImage: "plus")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .newTab))
            .disabled(focusedPane == nil)

            Button {
                logger.info("Cmd-W action fired (Tab → Close Tab)")
                store.requestCloseFocusedTab()
            } label: {
                Label("Close Tab", systemImage: "xmark")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .closeTab))
            .disabled(store.selectedSession == nil)

            Divider()

            Button {
                store.selectedSession?.focusedPane.selectPreviousTab()
            } label: {
                Label("Show Previous Tab", systemImage: "chevron.left")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .previousTab))
            .disabled((focusedPane?.tabs.count ?? 0) < 2)

            Button {
                store.selectedSession?.focusedPane.selectNextTab()
            } label: {
                Label("Show Next Tab", systemImage: "chevron.right")
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
                .keyboardShortcut(
                    KeyEquivalent(Character("\(index + 1)")),
                    modifiers: cmdNumberSwitchesSessions ? [.command, .option] : .command
                )
                .disabled(!tabExists(at: index))
            }
        }
    }

    private var cmdNumberSwitchesSessions: Bool {
        (CmdNumberTarget(rawValue: cmdNumberTarget) ?? .sessions) == .sessions
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

    private var isPinnedCurrentTheme: Bool {
        let pinned = PinnedThemes.load()
        return PinnedThemes.contains(activeThemeName, in: pinned)
    }

    private func togglePinCurrentTheme() {
        var pinned = PinnedThemes.load()
        PinnedThemes.toggle(activeThemeName, in: &pinned)
        PinnedThemes.save(pinned)
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
