// BattyCommands.swift

import AppKit
import OSLog
import SwiftUI

private struct NewWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    let shortcuts: ShortcutsStore

    var body: some View {
        Button("New Window") {
            openWindow(value: AppStateStore.shared.windowIDForNewWindow())
        }
        .keyboardShortcut(shortcuts.keyboardShortcut(for: .newWindow))
    }
}

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "BattyCommands")

public struct BattyCommands: Commands {
    /// The menu item's title as shown, in the running locale. Looked up when
    /// the app opens its first window itself because SwiftUI did not (#0444);
    /// the menu item is the only path to the scene's `openWindow` action while
    /// no window exists. `NewWindowButton`'s `Button("New Window")` and
    /// `ShortcutAction.newWindow.displayName` resolve the same "New Window"
    /// key in the same bundle, so the title stays localizable and the match
    /// stays language-independent.
    public static var newWindowMenuTitle: String { ShortcutAction.newWindow.displayName }

    @AppStorage(ThemePreference.darkDefaultsKey) private var darkThemeName: String = ""
    @AppStorage(ThemePreference.lightDefaultsKey) private var lightThemeName: String = ""
    @AppStorage(SettingsPreference.cmdNumberTargetKey) private var cmdNumberTarget: String = SettingsPreference.defaultCmdNumberTarget
    @Environment(\.colorScheme) private var colorScheme

    /// The theme name for whichever appearance is currently active.
    private var activeThemeName: String {
        colorScheme == .dark ? darkThemeName : lightThemeName
    }

    private var store: AppStateStore { AppStateStore.shared }
    private var shortcuts: ShortcutsStore { ShortcutsStore.shared }
    /// The key content window's runtime, if any. Menu commands that operate
    /// on sessions, panes, or tabs target this runtime instead of windows[0]
    /// (#0239: carried over from #0237). Falls back through
    /// `defaultTargetWindow()`'s full policy (#0439) — most recently key,
    /// then newest registered, then `windows.first` — so previews/tests
    /// without a key window still resolve one.
    ///
    /// Deliberately optional, not `store.windows[0]` (#0311): this `Commands`
    /// body can be re-evaluated by SwiftUI while `windows` is briefly empty —
    /// e.g. during the last content window's own close teardown, where
    /// AppKit's `terminate:` path can spin the run loop and flush a pending
    /// SwiftUI transaction that re-evaluates this body mid-teardown. An
    /// unguarded `windows[0]` traps (`EXC_BREAKPOINT`) in that window;
    /// `AppStateStore.keyWindowOrFirstRegistered()` degrades to `nil`
    /// instead. Every menu item below must guard/disable on this being nil
    /// rather than force-unwrap it. The fallback logic itself is delegated
    /// to `AppStateStore` rather than inlined here so it has a real unit
    /// test — see `keyWindowOrFirstRegistered()`'s doc comment.
    private var keyWindow: WindowRuntime? { store.keyWindowOrFirstRegistered() }

    /// What a menu action acts on: `keyWindow`, except nil while an auxiliary
    /// window (Settings, Help) is key, so a menu-routed chord does not reach
    /// the content window behind it. Read only inside action closures.
    /// Enablement and labels read `keyWindow`: the `Commands` body can re-run
    /// while one of those windows is key, and nothing observed changes when
    /// focus returns to a content window, so anything derived from the
    /// key-window state there could stay stale.
    private var actionWindow: WindowRuntime? { store.menuTargetWindow() }

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            NewWindowButton(shortcuts: shortcuts)

            Divider()

            Button("New Session") {
                logger.info("Cmd-N action fired (File → New Session)")
                actionWindow?.addSession()
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .newSession))
            .disabled(keyWindow == nil)

            Divider()

            Button {
                postToContentWindow(.battyToggleOpenQuickly)
            } label: {
                Label("Open Quickly\u{2026}", systemImage: "bolt")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .openQuickly))
            .disabled(keyWindow?.selectedSession == nil)
        }

        CommandGroup(after: .sidebar) {
            Button {
                postToContentWindow(.battyToggleSidebar)
            } label: {
                Label(
                    String(localized: "Toggle Sidebar"),
                    systemImage: "sidebar.left"
                )
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .toggleSidebar))
        }

        CommandMenu("Session") {
            Button {
                actionWindow?.addSession()
            } label: {
                Label("New Session", systemImage: "plus.square")
            }
            .disabled(keyWindow == nil)

            Divider()

            Button {
                postToContentWindow(.battyToggleLayoutPicker)
            } label: {
                Label("Choose Layout\u{2026}", systemImage: "rectangle.3.group")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .layoutPicker))
            .disabled(keyWindow?.selectedSession?.tree.allPanes.count != 1)

            Divider()

            ForEach(0..<9) { index in
                Button {
                    actionWindow?.selectSession(at: index)
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
                postToContentWindow(.battyToggleThemeSelector)
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

            ForEach(BattyThemeCatalog.allThemes, id: \.id) { theme in
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
                postToContentWindow(.battyToggleBellFeed)
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
            // #0453: the four view kinds named at the Pane menu's top level.
            // Each opens beside the focused Pane in the default direction
            // and carries the horizontal chord's badge; the Split
            // Horizontally submenu rows below deliberately omit that badge
            // so a chord is advertised on exactly one item. In a content
            // window `BattyShortcuts` takes the chord before the menu does,
            // so it never runs twice. When an auxiliary window such as
            // Settings or Help is key, the menu item resolves no target and
            // does nothing: the new Pane would open in a content window the
            // user can't see.
            Section("Open View") {
                Button {
                    actionWindow?.createPane(kind: .gitStatus, direction: .horizontal)
                } label: {
                    Label(PaneContentKind.gitStatus.displayName, systemImage: "arrow.triangle.branch")
                }
                .keyboardShortcut(shortcuts.keyboardShortcut(for: .splitHorizontalGitStatus))
                .disabled(keyWindow?.selectedSession == nil)

                Button {
                    actionWindow?.createPane(kind: .processStatus, direction: .horizontal)
                } label: {
                    Label(PaneContentKind.processStatus.displayName, systemImage: "list.bullet.rectangle")
                }
                .keyboardShortcut(shortcuts.keyboardShortcut(for: .splitHorizontalProcessStatus))
                .disabled(keyWindow?.selectedSession == nil)

                Button {
                    actionWindow?.createPane(kind: .systemMetrics, direction: .horizontal)
                } label: {
                    Label(PaneContentKind.systemMetrics.displayName, systemImage: "gauge")
                }
                .keyboardShortcut(shortcuts.keyboardShortcut(for: .splitHorizontalSystemMetrics))
                .disabled(keyWindow?.selectedSession == nil)

                Button {
                    actionWindow?.createPane(kind: .lmStudioDashboard, direction: .horizontal)
                } label: {
                    Label(PaneContentKind.lmStudioDashboard.displayName, systemImage: "cpu")
                }
                .keyboardShortcut(shortcuts.keyboardShortcut(for: .splitHorizontalLMStudioDashboard))
                .disabled(keyWindow?.selectedSession == nil)
            }

            Divider()

            // #0331: "Split Horizontally"/"Split Vertically" became
            // submenus, each listing Terminal first (identical to today's
            // plain action — same call, same result) followed by the four
            // typed-Pane kinds, the menu counterpart to #0315's CLI
            // `batty pane split --view <kind>`. This was originally
            // attempted as an AppKit `NSMenuItem.isAlternate` pair —
            // Option-hover swapping "Split Horizontally" for a kind
            // submenu, leaving the plain click unchanged — per the user's
            // initial request. That is not implementable cleanly: the
            // alternate mechanism requires the alternate item to share the
            // primary's key equivalent plus exactly one more modifier
            // (Option), which for `Cmd-D`/`Cmd-Shift-D` forces
            // `Cmd-Option-D`/`Cmd-Shift-Option-D` — already the live
            // bindings for "Split Full-Height Column"/"Split Full-Width
            // Row" *in this same menu* (see below). Two rows visibly
            // claiming the same chord in one open menu is exactly the
            // collision the user asked to avoid, so this uses the
            // always-visible-submenu fallback the user explicitly
            // pre-approved for this case instead. Cost: a single click on
            // "Split Horizontally"/"Split Vertically" no longer performs
            // the terminal split directly — it opens the submenu, and
            // "Terminal" is the first item. `Cmd-D`/`Cmd-Shift-D` from the
            // keyboard are unaffected either way: `BattyShortcuts`' NSEvent
            // monitor dispatches those chords directly, independent of
            // this menu's structure.
            Menu {
                Button {
                    guard let tree = actionWindow?.selectedSession?.tree else { return }
                    tree.splitFocusedPane(direction: .horizontal, inheritingFrom: tree.focusedPane)
                } label: {
                    Label(PaneContentKind.terminal.displayName, systemImage: "rectangle.split.2x1")
                }
                .keyboardShortcut(shortcuts.keyboardShortcut(for: .splitHorizontal))

                Divider()

                Button {
                    actionWindow?.createPane(kind: .gitStatus, direction: .horizontal)
                } label: {
                    Label(PaneContentKind.gitStatus.displayName, systemImage: "arrow.triangle.branch")
                }

                Button {
                    actionWindow?.createPane(kind: .processStatus, direction: .horizontal)
                } label: {
                    Label(PaneContentKind.processStatus.displayName, systemImage: "list.bullet.rectangle")
                }

                Button {
                    actionWindow?.createPane(kind: .systemMetrics, direction: .horizontal)
                } label: {
                    Label(PaneContentKind.systemMetrics.displayName, systemImage: "gauge")
                }

                Button {
                    actionWindow?.createPane(kind: .lmStudioDashboard, direction: .horizontal)
                } label: {
                    Label(PaneContentKind.lmStudioDashboard.displayName, systemImage: "cpu")
                }
            } label: {
                Label("Split Horizontally", systemImage: "rectangle.split.2x1")
            }
            .disabled(keyWindow?.selectedSession == nil)

            Menu {
                Button {
                    guard let tree = actionWindow?.selectedSession?.tree else { return }
                    tree.splitFocusedPane(direction: .vertical, inheritingFrom: tree.focusedPane)
                } label: {
                    Label(PaneContentKind.terminal.displayName, systemImage: "rectangle.split.1x2")
                }
                .keyboardShortcut(shortcuts.keyboardShortcut(for: .splitVertical))

                Divider()

                Button {
                    actionWindow?.createPane(kind: .gitStatus, direction: .vertical)
                } label: {
                    Label(PaneContentKind.gitStatus.displayName, systemImage: "arrow.triangle.branch")
                }
                .keyboardShortcut(shortcuts.keyboardShortcut(for: .splitVerticalGitStatus))

                Button {
                    actionWindow?.createPane(kind: .processStatus, direction: .vertical)
                } label: {
                    Label(PaneContentKind.processStatus.displayName, systemImage: "list.bullet.rectangle")
                }
                .keyboardShortcut(shortcuts.keyboardShortcut(for: .splitVerticalProcessStatus))

                Button {
                    actionWindow?.createPane(kind: .systemMetrics, direction: .vertical)
                } label: {
                    Label(PaneContentKind.systemMetrics.displayName, systemImage: "gauge")
                }
                .keyboardShortcut(shortcuts.keyboardShortcut(for: .splitVerticalSystemMetrics))

                Button {
                    actionWindow?.createPane(kind: .lmStudioDashboard, direction: .vertical)
                } label: {
                    Label(PaneContentKind.lmStudioDashboard.displayName, systemImage: "cpu")
                }
                .keyboardShortcut(shortcuts.keyboardShortcut(for: .splitVerticalLMStudioDashboard))
            } label: {
                Label("Split Vertically", systemImage: "rectangle.split.1x2")
            }
            .disabled(keyWindow?.selectedSession == nil)

            Button {
                guard let tree = actionWindow?.selectedSession?.tree else { return }
                tree.splitFullDimension(direction: .horizontal, inheritingFrom: tree.focusedPane)
            } label: {
                Label("Split Full-Height Column", systemImage: "rectangle.split.2x1")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .splitFullHeightColumn))
            .disabled(keyWindow?.selectedSession == nil)

            Button {
                guard let tree = actionWindow?.selectedSession?.tree else { return }
                tree.splitFullDimension(direction: .vertical, inheritingFrom: tree.focusedPane)
            } label: {
                Label("Split Full-Width Row", systemImage: "rectangle.split.1x2")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .splitFullWidthRow))
            .disabled(keyWindow?.selectedSession == nil)

            Divider()

            Button {
                postToContentWindow(.battyToggleLayoutPicker)
            } label: {
                Label("Layouts\u{2026}", systemImage: "rectangle.3.group")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .layoutPicker))
            .disabled(keyWindow?.selectedSession?.tree.allPanes.count != 1)

            Divider()

            Button {
                actionWindow?.selectedSession?.focusPane(adjacent: .left)
            } label: {
                Label("Focus Pane Left", systemImage: "arrow.left")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .focusPaneLeft))
            .disabled(!canFocusAdjacentPane)

            Button {
                actionWindow?.selectedSession?.focusPane(adjacent: .right)
            } label: {
                Label("Focus Pane Right", systemImage: "arrow.right")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .focusPaneRight))
            .disabled(!canFocusAdjacentPane)

            Button {
                actionWindow?.selectedSession?.focusPane(adjacent: .up)
            } label: {
                Label("Focus Pane Above", systemImage: "arrow.up")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .focusPaneUp))
            .disabled(!canFocusAdjacentPane)

            Button {
                actionWindow?.selectedSession?.focusPane(adjacent: .down)
            } label: {
                Label("Focus Pane Below", systemImage: "arrow.down")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .focusPaneDown))
            .disabled(!canFocusAdjacentPane)

            Divider()

            Button {
                actionWindow?.selectedSession?.tree.resizeFocusedSplit(.left)
            } label: {
                Label("Move Split Divider Left", systemImage: "chevron.left")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .resizeSplitLeft))
            .disabled(!canFocusAdjacentPane)

            Button {
                actionWindow?.selectedSession?.tree.resizeFocusedSplit(.right)
            } label: {
                Label("Move Split Divider Right", systemImage: "chevron.right")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .resizeSplitRight))
            .disabled(!canFocusAdjacentPane)

            Button {
                actionWindow?.selectedSession?.tree.resizeFocusedSplit(.up)
            } label: {
                Label("Move Split Divider Up", systemImage: "chevron.up")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .resizeSplitUp))
            .disabled(!canFocusAdjacentPane)

            Button {
                actionWindow?.selectedSession?.tree.resizeFocusedSplit(.down)
            } label: {
                Label("Move Split Divider Down", systemImage: "chevron.down")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .resizeSplitDown))
            .disabled(!canFocusAdjacentPane)
        }

        CommandMenu("Tab") {
            // Every item in this menu resolves its target through
            // `focusedTerminalPane`, not `focusedPane` (#0315 review rounds
            // 1 and 2, finding 2): a non-terminal pane's one `TabRuntime`
            // is a structural placeholder (docs/pane-kinds.md §1's design
            // deferred, see PaneRuntime.kind's doc comment) that
            // `PaneView`'s non-terminal arm never renders — Cmd-T on a
            // focused non-terminal pane must not silently add an invisible
            // second one, and the rest of this menu must not act on the
            // first. `SessionRuntime.focusedTerminalPane` is the single
            // accessor every dispatch path (this menu, the
            // `BattyShortcuts` NSEvent monitor, the Command Palette) routes
            // through, so the gate lives in one place, not one copy per
            // path. **Close is the one deliberate exception** (#0334): a
            // non-terminal pane has no Tab to close, but it still needs a
            // ⌘W route to being closed, so that item alone targets
            // `focusedPane`/`closeFocusedItemTitle` and relabels itself
            // "Close Pane" rather than staying disabled.
            Button {
                actionWindow?.selectedSession?.focusedTerminalPane?.addTab()
            } label: {
                Label("New Tab", systemImage: "plus")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .newTab))
            .disabled(focusedTerminalPane == nil)

            Button {
                let title = keyWindow?.closeFocusedItemTitle ?? "Close Tab"
                logger.info("Cmd-W action fired (Tab menu, title=\(title, privacy: .public))")
                if store.auxiliaryWindowIsKey {
                    NSApp.keyWindow?.performClose(nil)
                } else {
                    actionWindow?.requestCloseFocusedTab()
                }
            } label: {
                // Title reflects what this actually does (#0334): a
                // focused non-terminal pane has no Tab bar, so ⌘W closes
                // the Pane itself, not a Tab — the label must say so
                // rather than claiming "Close Tab" for a close that isn't
                // one. See `WindowRuntime.closeFocusedItemTitle`.
                Label(keyWindow?.closeFocusedItemTitle ?? "Close Tab", systemImage: "xmark")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .closeTab))
            .disabled(keyWindow?.selectedSession == nil)

            Button {
                ExitDispatcher.sendExit(store: store)
            } label: {
                Label("Exit Shell", systemImage: "power")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .exitShell))
            .disabled(focusedTerminalPane?.activeTab == nil)

            Divider()

            Button {
                actionWindow?.selectedSession?.focusedTerminalPane?.selectPreviousTab()
            } label: {
                Label("Show Previous Tab", systemImage: "chevron.left")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .previousTab))
            .disabled((focusedTerminalPane?.tabs.count ?? 0) < 2)

            Button {
                actionWindow?.selectedSession?.focusedTerminalPane?.selectNextTab()
            } label: {
                Label("Show Next Tab", systemImage: "chevron.right")
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .nextTab))
            .disabled((focusedTerminalPane?.tabs.count ?? 0) < 2)

            Divider()

            ForEach(0..<9) { index in
                Button {
                    actionWindow?.selectedSession?.focusedTerminalPane?.selectTab(at: index)
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

    /// The toggles the content windows observe. Dropped while an auxiliary
    /// window is key, so they do not act on the window behind it. (Each
    /// receiver also requires its own window to be key, so with no content
    /// window key they are inert either way.)
    private func postToContentWindow(_ name: Notification.Name) {
        guard !store.auxiliaryWindowIsKey else { return }
        NotificationCenter.default.post(name: name, object: nil)
    }

    private var cmdNumberSwitchesSessions: Bool {
        (CmdNumberTarget(rawValue: cmdNumberTarget) ?? .sessions) == .sessions
    }

    private var focusedTerminalPane: PaneRuntime? {
        keyWindow?.selectedSession?.focusedTerminalPane
    }

    private var canFocusAdjacentPane: Bool {
        guard let session = keyWindow?.selectedSession else { return false }
        return session.tree.allPanes.count > 1
    }

    private func sessionMenuTitle(at index: Int) -> String {
        guard let keyWindow, keyWindow.sessions.indices.contains(index) else {
            return String(localized: "Session \(index + 1)")
        }
        return keyWindow.sessions[index].title
    }

    private func sessionExists(at index: Int) -> Bool {
        keyWindow?.sessions.indices.contains(index) ?? false
    }

    private func tabMenuTitle(at index: Int) -> String {
        let fallback = String(localized: "Tab \(index + 1)")
        guard let pane = focusedTerminalPane, pane.tabs.indices.contains(index) else {
            return fallback
        }
        return TabTitleFormatter.chipTitle(for: pane.tabs[index], fallback: fallback)
    }

    private func tabExists(at index: Int) -> Bool {
        focusedTerminalPane?.tabs.indices.contains(index) ?? false
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
        if colorScheme == .dark {
            darkThemeName = theme.name
        } else {
            lightThemeName = theme.name
        }
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
