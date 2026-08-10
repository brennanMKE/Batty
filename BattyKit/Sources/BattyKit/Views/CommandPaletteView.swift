// CommandPaletteView.swift

import AppKit
import OSLog
import SwiftUI

extension Notification.Name {
    public static let battyToggleCommandPalette = Notification.Name("co.sstools.Batty.toggleCommandPalette")
}

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "CommandPaletteView")

struct PaletteCommand: Identifiable {
    /// Stable, content-derived id. `allCommands` is a computed property that
    /// re-runs on every body evaluation; if `id` were a fresh `UUID()` per
    /// access SwiftUI's `ForEach` would see new identities each render and
    /// the filtered output could render with stale row labels.
    let id: String
    let title: String
    let keyHint: String?
    let action: @MainActor () -> Void
}

enum CommandPaletteFilter {
    /// Filters and ranks commands against `query`. A command matches when the
    /// query is a subsequence of its title. Empty query returns all commands
    /// in their original order.
    static func apply(query: String, to commands: [PaletteCommand]) -> [PaletteCommand] {
        guard !query.isEmpty else { return commands }
        let scored: [(PaletteCommand, Int)] = commands.compactMap { cmd in
            let score = FuzzyMatcher.score(query, in: cmd.title)
            return score > 0 ? (cmd, score) : nil
        }
        return scored
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }
}

struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    let store: AppStateStore

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var queryFocused: Bool

    // Not `private` (#0316): CommandPaletteViewTests exercises the
    // no-window guard in the "Duplicate Session" action directly against
    // this list rather than re-typing the closure's body in a test.
    var allCommands: [PaletteCommand] {
        let shortcuts = ShortcutsStore.shared
        var cmds: [PaletteCommand] = []

        for action in ShortcutAction.allCases where action != .commandPalette {
            let hint = shortcuts.binding(for: action).displayString
            cmds.append(PaletteCommand(
                id: "action:\(action.rawValue)",
                title: action.displayName,
                keyHint: hint.isEmpty ? nil : hint,
                action: { self.dispatch(action) }
            ))
        }

        cmds.append(PaletteCommand(
            id: "extra:duplicateSession",
            title: String(localized: "Duplicate Session"),
            keyHint: nil,
            action: {
                // No window (#0316): store.windows[0] traps; nothing to
                // duplicate into anyway, so no-op.
                guard let w = store.keyWindowOrFirstRegistered() else { return }
                if let id = w.selectedSessionID {
                    w.duplicateSession(id: id)
                }
            }
        ))

        cmds.append(PaletteCommand(
            id: "extra:markAllBellsSeen",
            title: String(localized: "Mark All Bells Seen"),
            keyHint: nil,
            action: { store.markAllBellsSeen() }
        ))

        if UpdaterController.shared.isConfigured {
            cmds.append(PaletteCommand(
                id: "extra:checkForUpdates",
                title: String(localized: "Check for Updates…"),
                keyHint: nil,
                action: { UpdaterController.shared.checkForUpdates() }
            ))
        }

        cmds.append(PaletteCommand(
            id: "extra:aboutBatty",
            title: String(localized: "About Batty"),
            keyHint: nil,
            action: { AboutPanel.show() }
        ))

        for theme in BattyThemeCatalog.allThemes {
            cmds.append(PaletteCommand(
                id: "theme:\(theme.name)",
                title: String(localized: "Theme: \(theme.name)"),
                keyHint: nil,
                action: {
                    let key = ThemePreference.defaultsKey(isDark: NSApp.effectiveAppearance.isDark)
                    UserDefaults.standard.set(theme.name, forKey: key)
                    store.applyThemeToAllSurfaces(theme)
                }
            ))
        }

        return cmds
    }

    private var filteredCommands: [PaletteCommand] {
        CommandPaletteFilter.apply(query: query, to: allCommands)
    }

    var body: some View {
        // Snapshot once per render so ForEach, key handlers, and Return
        // activation all see the same list — avoids SwiftUI identity
        // confusion when the filter is re-evaluated mid-body.
        let commands = filteredCommands
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter commands…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($queryFocused)
                    .onKeyPress(.upArrow) { moveSelection(-1, in: commands); return .handled }
                    .onKeyPress(.downArrow) { moveSelection(1, in: commands); return .handled }
                    .onKeyPress(.return) { activate(commands: commands); return .handled }
                    .onKeyPress(.escape) { isPresented = false; return .handled }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if commands.isEmpty {
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
                            ForEach(Array(commands.enumerated()), id: \.element.id) { idx, cmd in
                                PaletteCommandRow(command: cmd, isSelected: idx == selectedIndex)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedIndex = idx
                                        activate(commands: commands)
                                    }
                            }
                        }
                    }
                    .onChange(of: selectedIndex) { _, newIdx in
                        if commands.indices.contains(newIdx) {
                            withAnimation { proxy.scrollTo(commands[newIdx].id, anchor: .center) }
                        }
                    }
                    .onChange(of: query) { _, _ in selectedIndex = 0 }
                }
            }
        }
        .frame(width: 580, height: 420)
        .background(.regularMaterial)
        .accessibilityIdentifier("command-palette.root")
        .onAppear { queryFocused = true }
    }

    private func moveSelection(_ delta: Int, in commands: [PaletteCommand]) {
        let count = commands.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func activate(commands: [PaletteCommand]) {
        guard commands.indices.contains(selectedIndex) else { return }
        let cmd = commands[selectedIndex]
        isPresented = false
        cmd.action()
    }

    // Not `private` (#0316): CommandPaletteViewTests calls this directly to
    // exercise the no-window guard against production code, not a copy of it.
    func dispatch(_ action: ShortcutAction) {
        logger.info("command palette dispatching \(action.rawValue, privacy: .public)")
        // Target the key window's runtime for per-window actions (#0239:
        // carried over from #0237). Falls back to windows.first without a
        // key window (previews, tests). No-ops (#0316) rather than trapping
        // when windows is empty — this palette can only be showing over a
        // real content window in practice, so that state is not expected to
        // be reachable here, but guarding is cheap and the alternative is a
        // trap.
        guard let window = store.keyWindowOrFirstRegistered() else {
            logger.notice("command palette dispatch: no window available; ignoring \(action.rawValue, privacy: .public)")
            return
        }
        switch action {
        case .newSession:
            window.addSession()
        case .closeTab:
            // `requestCloseFocusedTab()` itself branches on
            // `SessionRuntime.focusedTerminalPane` (#0315 review round 2,
            // finding 2 — this dispatch was found completely ungated, the
            // same defect round 1 fixed in the menu bar and the
            // `BattyShortcuts` NSEvent monitor but missed here): closes the
            // active Tab for a `.terminal` focused pane, or the Pane
            // itself otherwise (#0334).
            window.requestCloseFocusedTab()
        case .newTab:
            window.selectedSession?.focusedTerminalPane?.addTab(
                inheritingCWDFrom: window.selectedSession?.focusedTerminalPane?.activeTab
            )
        case .splitHorizontal:
            if let tree = window.selectedSession?.tree {
                tree.splitFocusedPane(direction: .horizontal, inheritingFrom: tree.focusedPane)
            }
        case .splitVertical:
            if let tree = window.selectedSession?.tree {
                tree.splitFocusedPane(direction: .vertical, inheritingFrom: tree.focusedPane)
            }
        case .splitFullHeightColumn:
            if let tree = window.selectedSession?.tree {
                tree.splitFullDimension(direction: .horizontal, inheritingFrom: tree.focusedPane)
            }
        case .splitFullWidthRow:
            if let tree = window.selectedSession?.tree {
                tree.splitFullDimension(direction: .vertical, inheritingFrom: tree.focusedPane)
            }
        case .focusPaneLeft:
            window.selectedSession?.focusPane(adjacent: .left)
        case .focusPaneRight:
            window.selectedSession?.focusPane(adjacent: .right)
        case .focusPaneUp:
            window.selectedSession?.focusPane(adjacent: .up)
        case .focusPaneDown:
            window.selectedSession?.focusPane(adjacent: .down)
        case .previousTab:
            window.selectedSession?.focusedTerminalPane?.selectPreviousTab()
        case .nextTab:
            window.selectedSession?.focusedTerminalPane?.selectNextTab()
        case .toggleSidebar:
            NotificationCenter.default.post(name: .battyToggleSidebar, object: nil)
        case .toggleBellFeed:
            NotificationCenter.default.post(name: .battyToggleBellFeed, object: nil)
        case .commandPalette:
            break
        case .openQuickly:
            NotificationCenter.default.post(name: .battyToggleOpenQuickly, object: nil)
        case .layoutPicker:
            NotificationCenter.default.post(name: .battyToggleLayoutPicker, object: nil)
        case .themeSelector:
            NotificationCenter.default.post(name: .battyToggleThemeSelector, object: nil)
        case .newWindow:
            AppStateStore.shared.openWindowAction?()
        case .exitShell:
            ExitDispatcher.sendExit(store: store)
        case .resizeSplitLeft:
            window.selectedSession?.tree.resizeFocusedSplit(.left)
        case .resizeSplitRight:
            window.selectedSession?.tree.resizeFocusedSplit(.right)
        case .resizeSplitUp:
            window.selectedSession?.tree.resizeFocusedSplit(.up)
        case .resizeSplitDown:
            window.selectedSession?.tree.resizeFocusedSplit(.down)
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
