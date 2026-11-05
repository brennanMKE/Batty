// AppWideBackgroundLiveApplyTests.swift

import Foundation
import GhosttyTerminal
import Testing
@testable import BattyKit

@MainActor
final class AppWideBackgroundLiveApplyTests {
    private static let path = "/tmp/batty-live-apply-tests/photo.png"
    private static let otherPath = "/tmp/batty-live-apply-tests/other.png"
    private static let settings = TerminalBackgroundSettings(
        imagePath: path, fit: .contain, position: .topLeft, imageOpacity: 0.35, terminalOpacity: 0.5
    )
    private static let settingsLines = [
        "background-image = \"\(path)\"",
        "background-image-fit = contain",
        "background-image-position = top-left",
        "background-image-opacity = 0.35",
        "background-opacity = 0.5",
    ]

    private let testDefaults = TestDefaults()
    private var defaults: UserDefaults { testDefaults.defaults }

    @MainActor deinit { testDefaults.tearDown() }

    private func makeStore(sessions: [SessionRuntime] = []) -> AppStateStore {
        AppStateStore(
            sessions: sessions,
            preferences: defaults,
            backgroundGate: .acceptingEveryImage(defaults: defaults)
        )
    }

    private func allTabs(_ store: AppStateStore) -> [TabRuntime] {
        store.windows.flatMap(\.sessions).flatMap { $0.tree.allPanes.flatMap(\.tabs) }
    }

    private func lines(_ tab: TabRuntime) -> [String] {
        tab.terminal.renderedConfig.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private func backgroundLines(_ tab: TabRuntime) -> [String] {
        lines(tab).filter { $0.hasPrefix("background-") }
    }

    private func push(_ settings: TerminalBackgroundSettings, to store: AppStateStore) {
        SettingsPreference.writeBackground(settings, defaults: defaults)
        store.applyAppWideBackgroundToAllSurfaces()
    }

    /// A Theme that differs from whatever a new Tab started with.
    private func differentTheme(from tab: TabRuntime) throws -> GhosttyThemeDefinition {
        try #require(BattyThemeCatalog.allThemes.first { $0.toTerminalTheme() != tab.terminal.controller.theme })
    }

    @Test func changeReachesFollowingPanesInEveryWindow() {
        let store = makeStore()
        _ = store.openWindowRuntime(for: WindowID())
        #expect(store.windows.count >= 2)
        push(Self.settings, to: store)
        for window in store.windows {
            let tabs = window.sessions.flatMap { $0.tree.allPanes.flatMap(\.tabs) }
            #expect(!tabs.isEmpty)
            for tab in tabs {
                #expect(backgroundLines(tab) == Self.settingsLines)
            }
        }
    }

    @Test func changeSkipsAnOverriddenPane() throws {
        let store = makeStore()
        let session = try #require(store.windows.first?.sessions.first)
        let overridden = try #require(session.tree.allPanes.first)
        let following = session.tree.splitFocusedPane(direction: .horizontal)
        overridden.setBackgroundOverride(TerminalBackgroundSettings(imagePath: Self.otherPath, fit: .stretch))
        let before = backgroundLines(overridden.tabs[0])
        #expect(before.contains("background-image-fit = stretch"))
        push(Self.settings, to: store)
        #expect(backgroundLines(overridden.tabs[0]) == before)
        #expect(backgroundLines(following.tabs[0]) == Self.settingsLines)
    }

    @Test func changeKeepsPerTabLines() {
        let store = makeStore()
        push(Self.settings, to: store)
        for tab in allTabs(store) {
            #expect(lines(tab).contains("keybind = clear"))
            #expect(lines(tab).contains("copy-on-select = false"))
            #expect(lines(tab).contains("env = BATTY_TAB_ID=\(tab.id.uuidString)"))
        }
    }

    @Test func changeSkipsANonTerminalPane() {
        let pane = PaneRuntime(kind: .systemMetrics, contentFactory: { _ in nil })
        let store = makeStore(sessions: [SessionRuntime(tree: SplitTree(root: .leaf(pane)))])
        let before = pane.tabs[0].terminal.renderedConfig
        push(Self.settings, to: store)
        #expect(pane.tabs[0].terminal.renderedConfig == before)
    }

    @Test func changeKeepsTheTheme() throws {
        let store = makeStore()
        let tab = try #require(allTabs(store).first)
        let theme = try differentTheme(from: tab)
        store.applyThemeToAllSurfaces(theme)
        let expected = theme.toTerminalTheme()
        let themeLine = try #require(lines(tab).first { $0.hasPrefix("background = ") })
        push(Self.settings, to: store)
        #expect(tab.terminal.controller.theme == expected)
        #expect(lines(tab).contains(themeLine))
        #expect(backgroundLines(tab) == Self.settingsLines)
    }

    @Test func themeChangeKeepsTheAppWideBackground() throws {
        let store = makeStore()
        push(Self.settings, to: store)
        let tab = try #require(allTabs(store).first)
        let theme = try differentTheme(from: tab)
        store.applyThemeToAllSurfaces(theme)
        #expect(tab.terminal.controller.theme == theme.toTerminalTheme())
        #expect(lines(tab).contains { $0.hasPrefix("background = ") })
        #expect(backgroundLines(tab) == Self.settingsLines)
    }

    @Test func appearanceChangeKeepsAppWideBackground() {
        let store = makeStore()
        push(Self.settings, to: store)
        defaults.set(21.0, forKey: SettingsPreference.fontSizeKey)
        store.applyAppearanceToAllSurfaces()
        for tab in allTabs(store) {
            #expect(lines(tab).contains("font-size = 21"))
            #expect(backgroundLines(tab) == Self.settingsLines)
        }
    }

    @Test func newTabAfterAChangeCarriesIt() {
        let pane = PaneRuntime(tabBackgroundGate: .acceptingEveryImage(defaults: defaults))
        let store = makeStore(sessions: [SessionRuntime(tree: SplitTree(root: .leaf(pane)))])
        push(Self.settings, to: store)
        #expect(backgroundLines(pane.addTab()) == Self.settingsLines)
    }

    @Test func clearingReturnsFollowingPanesToNothing() {
        let store = makeStore()
        push(Self.settings, to: store)
        SettingsPreference.clearBackground(defaults: defaults)
        store.applyAppWideBackgroundToAllSurfaces()
        for tab in allTabs(store) {
            #expect(backgroundLines(tab).isEmpty)
        }
    }

    // MARK: - The editor

    @Test func editorRestoreDefaultsEmitsNothingAndRemovesEveryKey() {
        let store = makeStore()
        push(Self.settings.withOpacityAffectsCells(true), to: store)
        AppWideBackgroundEditor(store: store).reset()
        for tab in allTabs(store) {
            #expect(backgroundLines(tab).isEmpty)
        }
        for key in [
            SettingsPreference.backgroundImagePathKey,
            SettingsPreference.backgroundImageFitKey,
            SettingsPreference.backgroundImagePositionKey,
            SettingsPreference.backgroundImageOpacityKey,
            SettingsPreference.backgroundOpacityKey,
            SettingsPreference.backgroundOpacityCellsKey,
        ] {
            #expect(defaults.object(forKey: key) == nil, "\(key)")
        }
    }

    @Test func editorWritesRealDoubles() {
        AppWideBackgroundEditor(store: makeStore()).update { $0.withTerminalOpacity(0.5).withImageOpacity(0.25) }
        #expect(defaults.object(forKey: SettingsPreference.backgroundOpacityKey) is NSNumber)
        #expect(defaults.object(forKey: SettingsPreference.backgroundImageOpacityKey) is NSNumber)
        #expect(SettingsPreference.resolvedBackground(defaults: defaults).terminalOpacity == 0.5)
    }

    @Test func editorFirstPickAppliesTheTint() {
        let store = makeStore()
        AppWideBackgroundEditor(store: store).pickImage(path: Self.path)
        let stored = SettingsPreference.resolvedBackground(defaults: defaults)
        #expect(stored.imagePath == Self.path)
        #expect(stored.imageOpacity == TerminalBackgroundSettings.firstImageOpacity)
        for tab in allTabs(store) {
            #expect(lines(tab).contains("background-image = \"\(Self.path)\""))
        }
    }

    @Test func editorReplacingAnImageKeepsItsOpacity() {
        let store = makeStore()
        push(TerminalBackgroundSettings(imagePath: Self.path, imageOpacity: 0.9), to: store)
        AppWideBackgroundEditor(store: store).pickImage(path: Self.otherPath)
        let stored = SettingsPreference.resolvedBackground(defaults: defaults)
        #expect(stored.imagePath == Self.otherPath)
        #expect(stored.imageOpacity == 0.9)
    }

    /// A repaired copy keeps its path, so nothing but a re-inspection brings
    /// the image back.
    @Test func editorPickAtTheSamePathInspectsAgainAndPushes() {
        var state = BackgroundImageState.rejected
        let gate = AppWideBackgroundGate(defaults: defaults) { _ in state }
        let store = AppStateStore(preferences: defaults, backgroundGate: gate)
        push(Self.settings, to: store)
        for tab in allTabs(store) {
            #expect(!lines(tab).contains { $0.hasPrefix("background-image") })
        }
        state = .usable
        AppWideBackgroundEditor(store: store).pickImage(path: Self.path)
        for tab in allTabs(store) {
            #expect(lines(tab).contains("background-image = \"\(Self.path)\""))
        }
    }

    @Test func editorEqualUpdateDoesNotPush() throws {
        let store = makeStore()
        let tab = try #require(allTabs(store).first)
        let before = tab.terminal.renderedConfig
        AppWideBackgroundEditor(store: store).update { $0 }
        #expect(tab.terminal.renderedConfig == before)
        #expect(defaults.object(forKey: SettingsPreference.backgroundImageFitKey) == nil)
    }

    private func countingGate(_ count: @escaping () -> Void) -> AppWideBackgroundGate {
        AppWideBackgroundGate(defaults: defaults) { _ in
            count()
            return .usable
        }
    }

    @Test func editorUpdatesDoNotInspectTheImageAgain() {
        var inspections = 0
        let store = AppStateStore(preferences: defaults, backgroundGate: countingGate { inspections += 1 })
        let editor = AppWideBackgroundEditor(store: store)
        editor.pickImage(path: Self.path)
        let afterPick = inspections
        for step in 1...10 {
            let opacity = Double(step) / 20
            let updated = editor.update { $0.withTerminalOpacity(opacity) }
            #expect(updated.terminalOpacity == opacity)
        }
        #expect(inspections == afterPick)
        for tab in allTabs(store) {
            #expect(lines(tab).contains("background-opacity = 0.5"))
            #expect(lines(tab).contains("background-image = \"\(Self.path)\""))
        }
    }

    @Test func editorInspectsOnAppearPickAndNothingElse() {
        var inspections = 0
        let store = AppStateStore(preferences: defaults, backgroundGate: countingGate { inspections += 1 })
        let editor = AppWideBackgroundEditor(store: store)
        #expect(editor.pickImage(path: Self.path).imageState == .usable)
        #expect(inspections == 1)
        #expect(editor.inspect().imageState == .usable)
        #expect(inspections == 2)
        #expect(editor.removeImage() == AppWideBackgroundEditor.Snapshot(
            settings: SettingsPreference.resolvedBackground(defaults: defaults),
            imageState: .none
        ))
        #expect(inspections == 2)
    }

    /// The opacity controls stay enabled without an image, so this is what the
    /// Settings slider and field do on a machine with no image set.
    @Test func editorTerminalOpacityWithNoImageReachesEveryFollowingTab() {
        let store = makeStore()
        AppWideBackgroundEditor(store: store).update { $0.withTerminalOpacity(0.5) }
        let tabs = allTabs(store)
        #expect(!tabs.isEmpty)
        for tab in tabs {
            #expect(backgroundLines(tab) == ["background-opacity = 0.5"])
        }
    }

    @Test func typedValueOffTheSliderGridIsStoredAndEmittedUnsnapped() {
        let store = makeStore()
        let editor = AppWideBackgroundEditor(store: store)
        editor.pickImage(path: Self.path)
        let terminal = OpacityPercent.value(afterCommitting: "37", current: editor.stored.terminalOpacity)
        let image = OpacityPercent.value(afterCommitting: "62", current: editor.stored.imageOpacity)
        editor.update { $0.withTerminalOpacity(terminal).withImageOpacity(image) }
        #expect(editor.stored.terminalOpacity == 0.37)
        #expect(editor.stored.imageOpacity == 0.62)
        for tab in allTabs(store) {
            #expect(lines(tab).contains("background-opacity = 0.37"))
            #expect(lines(tab).contains("background-image-opacity = 0.62"))
        }
    }
}
