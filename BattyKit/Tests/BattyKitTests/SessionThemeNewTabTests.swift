// SessionThemeNewTabTests.swift

import Foundation
import GhosttyTerminal
import Testing
@testable import BattyKit

@MainActor
struct SessionThemeNewTabTests {
    private let testDefaults = TestDefaults()
    private let globalDark: GhosttyThemeDefinition
    private let globalLight: GhosttyThemeDefinition
    private let x: GhosttyThemeDefinition
    private let y: GhosttyThemeDefinition

    init() {
        let avoid = Set([ThemePreference.activeTheme(isDark: true)?.name, ThemePreference.activeTheme(isDark: false)?.name].compactMap { $0 })
        let pool = BattyThemeCatalog.allThemes.filter { !avoid.contains($0.name) }
        globalDark = pool[0]
        globalLight = pool[1]
        x = pool[2]
        y = pool[3]
    }

    private func makeStore() -> AppStateStore {
        let defaults = testDefaults.defaults
        defaults.set(true, forKey: ThemePreference.migrationDoneKey)
        defaults.set(globalDark.name, forKey: ThemePreference.darkDefaultsKey)
        defaults.set(globalLight.name, forKey: ThemePreference.lightDefaultsKey)
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-session-theme-\(UUID().uuidString)")
            .appendingPathComponent("session-name-cache.json")
        let cache = SessionNameCache(fileURL: cacheURL, debounce: .zero, homeDirectory: "/Users/test")
        return AppStateStore(nameCache: cache, preferences: defaults)
    }

    private func uses(_ theme: GhosttyThemeDefinition, _ tab: TabRuntime) -> Bool {
        tab.terminal.controller.theme == theme.toTerminalTheme()
    }

    @Test func addTabStartsWithSessionTheme() {
        let session = SessionRuntime()
        session.themeOverride = ThemePair(dark: x.name, light: x.name)
        let tab = session.tree.focusedPane.addTab()
        #expect(uses(x, tab))
    }

    @Test func storeAddTabStartsWithSessionTheme() throws {
        let store = makeStore()
        let session = store.sessions[0]
        session.themeOverride = ThemePair(dark: x.name, light: x.name)
        let tab = try #require(store.addTab(toPaneID: session.tree.focusedPane.id))
        #expect(uses(x, tab))
    }

    @Test func clearedOverrideNewTabFollowsGlobal() {
        let session = SessionRuntime()
        session.themeOverride = ThemePair(dark: x.name, light: x.name)
        session.themeOverride = nil
        let tab = session.tree.focusedPane.addTab()
        #expect(!uses(x, tab))
    }

    @Test func splitFocusedPaneStartsWithSessionTheme() {
        let session = SessionRuntime()
        session.themeOverride = ThemePair(dark: x.name, light: x.name)
        let pane = session.tree.splitFocusedPane(direction: .horizontal)
        #expect(!pane.tabs.isEmpty)
        #expect(pane.tabs.allSatisfy { uses(x, $0) })
        #expect(uses(x, pane.addTab()))
    }

    @Test func splitFullDimensionStartsWithSessionTheme() {
        let session = SessionRuntime()
        session.themeOverride = ThemePair(dark: x.name, light: x.name)
        let pane = session.tree.splitFullDimension(direction: .vertical)
        #expect(!pane.tabs.isEmpty)
        #expect(pane.tabs.allSatisfy { uses(x, $0) })
    }

    @Test func splitNonTerminalKindLeavesPlaceholderAlone() throws {
        let session = SessionRuntime()
        session.themeOverride = ThemePair(dark: x.name, light: x.name)
        let split = session.tree.splitPane(
            id: session.tree.focusedPane.id,
            direction: .horizontal,
            kind: .gitStatus,
            contentFactory: { _ in nil },
            isSessionSelected: true
        )
        let pane = try #require(split)
        #expect(pane.kind == .gitStatus)
        #expect(pane.tabs.allSatisfy { !uses(x, $0) })
    }

    @Test func splitInUnselectedSessionStartsWithSessionTheme() throws {
        let store = makeStore()
        let source = store.sessions[0]
        _ = try #require(store.duplicateSession(id: source.id))
        #expect(store.selectedSessionID != source.id)
        source.themeOverride = ThemePair(dark: x.name, light: x.name)
        let paneID = try #require(store.splitPane(id: source.tree.focusedPane.id, direction: .horizontal))
        let pane = try #require(source.tree.allPanes.first { $0.id == paneID })
        #expect(pane.tabs.allSatisfy { uses(x, $0) })
    }

    @Test func newTabFollowsPairSlotOnAppearanceFlip() {
        let store = makeStore()
        let session = store.sessions[0]
        session.themeOverride = ThemePair(dark: x.name, light: y.name)
        let tab = session.tree.focusedPane.addTab()
        store.applyGlobalThemeForCurrentAppearance(isDark: false)
        #expect(uses(y, tab))
        store.applyGlobalThemeForCurrentAppearance(isDark: true)
        #expect(uses(x, tab))
    }

    @Test func duplicateSessionCopiesThemeOverride() throws {
        let store = makeStore()
        let source = store.sessions[0]
        let pair = ThemePair(dark: x.name, light: y.name)
        source.themeOverride = pair
        let copy = try #require(store.duplicateSession(id: source.id))
        #expect(copy.themeOverride == pair)
        #expect(copy.tree.sessionThemeOverride == pair)
    }

    @Test func duplicateSessionWithoutOverrideStaysFollowing() throws {
        let store = makeStore()
        let copy = try #require(store.duplicateSession(id: store.sessions[0].id))
        #expect(copy.themeOverride == nil)
    }
}
