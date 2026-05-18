// CommandPaletteView.swift

import AppKit
import OSLog
import SwiftUI

extension Notification.Name {
    public static let battyToggleCommandPalette = Notification.Name("co.sstools.Batty.toggleCommandPalette")
}

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "CommandPaletteView")

struct PaletteCommand: Identifiable {
    let id = UUID()
    let title: String
    let keyHint: String?
    let action: @MainActor () -> Void
}

struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    let store: AppStateStore

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var queryFocused: Bool

    private var allCommands: [PaletteCommand] {
        let shortcuts = ShortcutsStore.shared
        var cmds: [PaletteCommand] = []

        for action in ShortcutAction.allCases where action != .commandPalette {
            let hint = shortcuts.binding(for: action).displayString
            cmds.append(PaletteCommand(
                title: action.displayName,
                keyHint: hint.isEmpty ? nil : hint,
                action: { self.dispatch(action) }
            ))
        }

        cmds.append(PaletteCommand(
            title: String(localized: "Duplicate Session"),
            keyHint: nil,
            action: {
                if let id = store.selectedSessionID {
                    store.duplicateSession(id: id)
                }
            }
        ))

        cmds.append(PaletteCommand(
            title: String(localized: "Mark All Bells Seen"),
            keyHint: nil,
            action: { store.markAllBellsSeen() }
        ))

        if UpdaterController.shared.isConfigured {
            cmds.append(PaletteCommand(
                title: String(localized: "Check for Updates…"),
                keyHint: nil,
                action: { UpdaterController.shared.checkForUpdates() }
            ))
        }

        cmds.append(PaletteCommand(
            title: String(localized: "About Batty"),
            keyHint: nil,
            action: { AboutPanel.show() }
        ))

        for theme in GhosttyThemeCatalog.allThemes {
            cmds.append(PaletteCommand(
                title: String(localized: "Theme: \(theme.name)"),
                keyHint: nil,
                action: {
                    UserDefaults.standard.set(theme.name, forKey: ThemePreference.defaultsKey)
                    store.applyThemeToAllSurfaces(theme)
                }
            ))
        }

        return cmds
    }

    private var filteredCommands: [PaletteCommand] {
        guard !query.isEmpty else { return allCommands }
        return allCommands
            .filter { FuzzyMatcher.matches(query, in: $0.title) }
            .sorted { FuzzyMatcher.score(query, in: $0.title) > FuzzyMatcher.score(query, in: $1.title) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter commands…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($queryFocused)
                    .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                    .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                    .onKeyPress(.return) { executeSelected(); return .handled }
                    .onKeyPress(.escape) { isPresented = false; return .handled }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if filteredCommands.isEmpty {
                ContentUnavailableView(
                    "No Commands Found",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different search term.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { idx, cmd in
                                PaletteCommandRow(command: cmd, isSelected: idx == selectedIndex)
                                    .id(idx)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedIndex = idx
                                        executeSelected()
                                    }
                            }
                        }
                    }
                    .onChange(of: selectedIndex) { _, newIdx in
                        withAnimation { proxy.scrollTo(newIdx, anchor: .center) }
                    }
                    .onChange(of: query) { _, _ in selectedIndex = 0 }
                }
            }
        }
        .frame(width: 580, height: 420)
        .background(.regularMaterial)
        .onAppear { queryFocused = true }
    }

    private func moveSelection(_ delta: Int) {
        let count = filteredCommands.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func executeSelected() {
        guard filteredCommands.indices.contains(selectedIndex) else { return }
        let cmd = filteredCommands[selectedIndex]
        isPresented = false
        cmd.action()
    }

    private func dispatch(_ action: ShortcutAction) {
        logger.info("command palette dispatching \(action.rawValue, privacy: .public)")
        switch action {
        case .newSession:
            store.addSession()
        case .closeTab:
            store.requestCloseFocusedTab()
        case .newTab:
            store.selectedSession?.focusedPane.addTab(
                inheritingCWDFrom: store.selectedSession?.focusedPane.activeTab
            )
        case .splitHorizontal:
            if let tree = store.selectedSession?.tree {
                tree.splitFocusedPane(direction: .horizontal, inheritingFrom: tree.focusedPane)
            }
        case .splitVertical:
            if let tree = store.selectedSession?.tree {
                tree.splitFocusedPane(direction: .vertical, inheritingFrom: tree.focusedPane)
            }
        case .focusPaneLeft:
            store.selectedSession?.focusPane(adjacent: .left)
        case .focusPaneRight:
            store.selectedSession?.focusPane(adjacent: .right)
        case .focusPaneUp:
            store.selectedSession?.focusPane(adjacent: .up)
        case .focusPaneDown:
            store.selectedSession?.focusPane(adjacent: .down)
        case .previousTab:
            store.selectedSession?.focusedPane.selectPreviousTab()
        case .nextTab:
            store.selectedSession?.focusedPane.selectNextTab()
        case .toggleSidebar:
            let defaults = UserDefaults.standard
            let current = defaults.bool(forKey: SidebarPreference.hiddenKey)
            defaults.set(!current, forKey: SidebarPreference.hiddenKey)
        case .toggleBellFeed:
            NotificationCenter.default.post(name: .battyToggleBellFeed, object: nil)
        case .commandPalette:
            break
        case .openQuickly:
            NotificationCenter.default.post(name: .battyToggleOpenQuickly, object: nil)
        }
    }
}

private struct PaletteCommandRow: View {
    let command: PaletteCommand
    let isSelected: Bool

    var body: some View {
        HStack {
            Text(command.title)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let hint = command.keyHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
    }
}
