// TerminalAppearancePushTests.swift

import Foundation
import GhosttyTerminal
import Testing
@testable import BattyKit

/// An appearance change alters the font and cursor lines and nothing else. No
/// test here reads font after a later background push: those re-renders read
/// `.standard`, which in production is the store's own `preferences`, so such
/// a test would pin a difference that exists only under test.
@MainActor
final class TerminalAppearancePushTests {
    private static let command = "/bin/cat"
    private static let appearanceLines = [
        "font-size = 21",
        "cursor-style = bar",
        "cursor-style-blink = false",
    ]
    private static let appearancePrefixes = ["font-size = ", "cursor-style = ", "cursor-style-blink = "]
    private static let sharedBindings = [
        "keybind = super+left=text:\\x01",
        "keybind = super+right=text:\\x05",
        "keybind = super+backspace=text:\\x15",
        "keybind = alt+left=text:\\x1bb",
        "keybind = alt+right=text:\\x1bf",
        "keybind = alt+backspace=text:\\x1b\\x7f",
    ]
    private static let paneOverride = TerminalBackgroundSettings(
        imagePath: "/tmp/batty-appearance-push-tests/pane.png", fit: .cover, position: .topLeft, imageOpacity: 0.35, terminalOpacity: 0.5
    )
    private static let sessionOverride = TerminalBackgroundSettings(
        imagePath: "/tmp/batty-appearance-push-tests/session.png", fit: .contain, position: .bottomCenter, imageOpacity: 0.55, terminalOpacity: 0.7
    )

    private let testDefaults = TestDefaults()
    private var defaults: UserDefaults { testDefaults.defaults }

    init() {
        defaults.set(21.0, forKey: SettingsPreference.fontSizeKey)
        defaults.set("bar", forKey: SettingsPreference.cursorStyleKey)
        defaults.set(false, forKey: SettingsPreference.cursorBlinkKey)
        defaults.set(0.5, forKey: SettingsPreference.backgroundOpacityKey)
    }

    @MainActor deinit { testDefaults.tearDown() }

    private var gate: AppWideBackgroundGate { .acceptingEveryImage(defaults: defaults) }

    private func lines(_ tab: TabRuntime) -> [String] {
        tab.terminal.renderedConfig.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private func linesWithoutAppearance(_ tab: TabRuntime) -> [String] {
        lines(tab).filter { line in !Self.appearancePrefixes.contains { line.hasPrefix($0) } }
    }

    private func envLines(_ tab: TabRuntime, name: String) -> [String] {
        lines(tab).filter { $0.hasPrefix("env = \(name)=") }
    }

    private func commandPane(gate: AppWideBackgroundGate) -> PaneRuntime {
        PaneRuntime(tabs: [TabRuntime(command: Self.command, backgroundGate: gate)], tabBackgroundGate: gate)
    }

    private func shellPane(gate: AppWideBackgroundGate, tabCount: Int = 2) -> PaneRuntime {
        PaneRuntime(tabs: (0..<tabCount).map { _ in TabRuntime(backgroundGate: gate) }, tabBackgroundGate: gate)
    }

    private func split(_ first: PaneRuntime, _ second: PaneRuntime) -> SessionRuntime {
        SessionRuntime(tree: SplitTree(root: .split(id: UUID(), direction: .horizontal, ratio: 0.5, left: .leaf(first), right: .leaf(second))))
    }

    private func store(_ sessions: [SessionRuntime], gate: AppWideBackgroundGate? = nil) -> AppStateStore {
        AppStateStore(sessions: sessions, preferences: defaults, backgroundGate: gate ?? self.gate)
    }

    private func assertKeepsPerTabLines(_ tab: TabRuntime, pane: PaneRuntime, session: SessionRuntime) {
        let lines = lines(tab)
        #expect(lines.contains("keybind = clear"))
        #expect(lines.contains("copy-on-select = false"))
        #expect(lines.contains("env = BATTY_TAB_ID=\(tab.id.uuidString)"))
        #expect(lines.contains("env = BATTY_PANE_ID=\(pane.id.uuidString)"))
        #expect(lines.contains("env = BATTY_SESSION_ID=\(session.id.uuidString)"))
    }

    // MARK: - The class guard

    @Test func appearanceChangeChangesOnlyAppearanceLines() {
        let commandPane = commandPane(gate: gate)
        let shellPane = shellPane(gate: gate)
        let store = store([split(commandPane, shellPane)])
        let tabs = commandPane.tabs + shellPane.tabs
        let before = tabs.map(linesWithoutAppearance)
        for tab in tabs {
            let lines = lines(tab)
            for line in Self.appearanceLines {
                #expect(!lines.contains(line), "the fixture must differ from what the Tab started with: \(line)")
            }
        }

        store.applyAppearanceToAllSurfaces()

        #expect(tabs.map(linesWithoutAppearance) == before)
    }

    @Test func appearanceChangeKeepsKeybindClearAndCopyBinding() {
        let pane = shellPane(gate: gate)
        store([SessionRuntime(tree: SplitTree(root: .leaf(pane)))]).applyAppearanceToAllSurfaces()
        for tab in pane.tabs {
            let keybinds = lines(tab).filter { $0.hasPrefix("keybind = ") }
            #expect(keybinds == ["keybind = clear", "keybind = cmd+c=copy_to_clipboard"] + Self.sharedBindings)
            #expect(lines(tab).contains("copy-on-select = false"))
        }
    }

    @Test func appearanceChangeKeepsCommandPaneLines() {
        let pane = commandPane(gate: gate)
        store([SessionRuntime(tree: SplitTree(root: .leaf(pane)))]).applyAppearanceToAllSurfaces()
        let lines = lines(pane.tabs[0])
        #expect(lines.contains("command = \(Self.command)"))
        #expect(lines.contains("wait-after-command = true"))
        #expect(lines.contains("abnormal-command-exit-runtime = 0"))
    }

    /// One configuration pushed to every Tab can't pass this.
    @Test func appearanceChangeKeepsEachTabsOwnIdentity() {
        let first = shellPane(gate: gate)
        let second = shellPane(gate: gate)
        let firstSession = SessionRuntime(tree: SplitTree(root: .leaf(first)))
        let secondSession = SessionRuntime(tree: SplitTree(root: .leaf(second)))
        store([firstSession, secondSession]).applyAppearanceToAllSurfaces()
        for (pane, session) in [(first, firstSession), (second, secondSession)] {
            for tab in pane.tabs {
                #expect(envLines(tab, name: "BATTY_TAB_ID") == ["env = BATTY_TAB_ID=\(tab.id.uuidString)"])
                #expect(envLines(tab, name: "BATTY_PANE_ID") == ["env = BATTY_PANE_ID=\(pane.id.uuidString)"])
                #expect(envLines(tab, name: "BATTY_SESSION_ID") == ["env = BATTY_SESSION_ID=\(session.id.uuidString)"])
            }
        }
    }

    @Test func appearanceChangeAppliesFontAndCursor() {
        let commandPane = commandPane(gate: gate)
        let shellPane = shellPane(gate: gate)
        store([split(commandPane, shellPane)]).applyAppearanceToAllSurfaces()
        for tab in commandPane.tabs + shellPane.tabs {
            let lines = lines(tab)
            for line in Self.appearanceLines {
                #expect(lines.contains(line), "missing \(line)")
            }
            #expect(tab.terminal.controller.lastConfigurationIssue == nil)
        }
    }

    @Test func appearanceChangeReachesOverriddenPanes() {
        let paneWithOverride = shellPane(gate: gate, tabCount: 1)
        let following = shellPane(gate: gate, tabCount: 1)
        let sessionWithOverride = shellPane(gate: gate, tabCount: 1)
        let session = SessionRuntime(tree: SplitTree(root: .leaf(sessionWithOverride)))
        let store = store([split(paneWithOverride, following), session])
        paneWithOverride.setBackgroundOverride(Self.paneOverride)
        session.setBackgroundOverride(Self.sessionOverride)
        let backgroundBefore = [paneWithOverride, sessionWithOverride].map { pane in
            lines(pane.tabs[0]).filter { $0.hasPrefix("background-") }
        }
        #expect(backgroundBefore[0].contains("background-image-fit = cover"))
        #expect(backgroundBefore[1].contains("background-image-fit = contain"))

        store.applyAppearanceToAllSurfaces()

        let backgroundAfter = [paneWithOverride, sessionWithOverride].map { pane in
            lines(pane.tabs[0]).filter { $0.hasPrefix("background-") }
        }
        #expect(backgroundAfter == backgroundBefore)
        #expect(lines(paneWithOverride.tabs[0]).contains("font-size = 21"))
        #expect(lines(sessionWithOverride.tabs[0]).contains("font-size = 21"))
    }

    /// The path Prod runs while `terminalBackgrounds` is off.
    @Test func appearanceChangeKeepsPerTabLinesWithBackgroundsFlagOff() {
        let gate = AppWideBackgroundGate(defaults: defaults, isEnabled: false) { _ in .usable }
        let pane = shellPane(gate: gate)
        let session = SessionRuntime(tree: SplitTree(root: .leaf(pane)))
        store([session], gate: gate).applyAppearanceToAllSurfaces()
        for tab in pane.tabs {
            assertKeepsPerTabLines(tab, pane: pane, session: session)
            #expect(lines(tab).contains("font-size = 21"))
            #expect(!lines(tab).contains { $0.hasPrefix("background-") })
        }
    }

    @Test func appearanceChangeRestoresATabMissingPerTabLines() {
        let pane = shellPane(gate: gate, tabCount: 1)
        let session = SessionRuntime(tree: SplitTree(root: .leaf(pane)))
        let store = store([session])
        let tab = pane.tabs[0]
        tab.terminal.controller.setTerminalConfiguration(TerminalConfiguration {
            $0.withSharedPreferences(fontSize: 13, cursor: .block, blink: true, background: .off)
        })
        #expect(!lines(tab).contains("keybind = clear"))

        store.applyAppearanceToAllSurfaces()

        assertKeepsPerTabLines(tab, pane: pane, session: session)
    }

    // MARK: - Negative controls

    /// Proves the assertions above can fail on what this push used to send.
    @Test func sharedPreferencesAloneOmitPerTabLines() {
        let tab = TabRuntime(backgroundGate: gate)
        tab.terminal.controller.setTerminalConfiguration(TerminalConfiguration {
            $0.withSharedPreferences(fontSize: 21, cursor: .bar, blink: false, background: .off)
        })
        let lines = lines(tab)
        #expect(lines.contains("font-size = 21"))
        #expect(!lines.contains("keybind = clear"))
        #expect(!lines.contains { $0.hasPrefix("copy-on-select") })
        #expect(!lines.contains { $0.hasPrefix("command") })
        #expect(!lines.contains { $0.hasPrefix("env = BATTY_") })
    }

    @Test func appearanceChangeAddsNoCommandLinesToAShellTab() {
        let pane = shellPane(gate: gate, tabCount: 1)
        store([SessionRuntime(tree: SplitTree(root: .leaf(pane)))]).applyAppearanceToAllSurfaces()
        let lines = lines(pane.tabs[0])
        #expect(!lines.contains { $0.hasPrefix("wait-after-command") })
        #expect(!lines.contains { $0.hasPrefix("abnormal-command-exit-runtime") })
        #expect(lines.filter { $0.hasPrefix("command = ") } == ["command = \(SettingsPreference.resolvedShell())"])
    }

    @Test func appearanceChangeLeavesNonTerminalPaneAlone() {
        let pane = PaneRuntime(kind: .systemMetrics, tabBackgroundGate: gate, contentFactory: { _ in nil })
        let store = store([SessionRuntime(tree: SplitTree(root: .leaf(pane)))])
        let before = pane.tabs[0].terminal.renderedConfig

        store.applyAppearanceToAllSurfaces()

        #expect(pane.tabs[0].terminal.renderedConfig == before)
    }
}
