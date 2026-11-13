// ThemeSelectionOwnershipTests.swift

import Foundation
import GhosttyTerminal
import Testing
@testable import BattyKit

@MainActor
struct ThemeSelectionOwnershipTests {
    private let testDefaults = TestDefaults()
    private let g: GhosttyThemeDefinition
    private let gl: GhosttyThemeDefinition
    private let a: GhosttyThemeDefinition
    private let b: GhosttyThemeDefinition

    init() {
        let avoid = Set([ThemePreference.activeTheme(isDark: true)?.name, ThemePreference.activeTheme(isDark: false)?.name].compactMap { $0 })
        let pool = BattyThemeCatalog.allThemes.filter { !avoid.contains($0.name) }
        g = pool[0]
        gl = pool[1]
        a = pool[2]
        b = pool[3]
    }

    private var defaults: UserDefaults { testDefaults.defaults }

    private func makeStore() -> AppStateStore {
        defaults.set(true, forKey: ThemePreference.migrationDoneKey)
        defaults.set(g.name, forKey: ThemePreference.darkDefaultsKey)
        defaults.set(gl.name, forKey: ThemePreference.lightDefaultsKey)
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-theme-ownership-\(UUID().uuidString)")
            .appendingPathComponent("session-name-cache.json")
        let cache = SessionNameCache(fileURL: cacheURL, debounce: .zero, homeDirectory: "/Users/test")
        return AppStateStore(nameCache: cache, preferences: defaults)
    }

    private func tabs(_ session: SessionRuntime) -> [TabRuntime] {
        session.tree.allPanes.filter { $0.kind == .terminal }.flatMap(\.tabs)
    }

    private func on(_ theme: GhosttyThemeDefinition, _ session: SessionRuntime) -> Bool {
        let all = tabs(session)
        return !all.isEmpty && all.allSatisfy { $0.terminal.controller.theme == theme.toTerminalTheme() }
    }

    private var darkSlot: String? { defaults.string(forKey: ThemePreference.darkDefaultsKey) }
    private var lightSlot: String? { defaults.string(forKey: ThemePreference.lightDefaultsKey) }

    // MARK: - setGlobalTheme

    @Test func setGlobalThemeWritesTheSlotAndRethemesFollowingSessions() throws {
        let store = makeStore()
        let session = try #require(store.sessions.first)
        store.applyTerminalTheme(g, to: session)
        store.setGlobalTheme(named: a.name, isDark: true, appearanceIsDark: true)
        #expect(darkSlot == a.name)
        #expect(on(a, session))
        #expect(lightSlot == gl.name)
    }

    @Test func setGlobalThemeForTheOtherAppearanceOnlyPersists() throws {
        let store = makeStore()
        let session = try #require(store.sessions.first)
        store.applyTerminalTheme(g, to: session)
        store.setGlobalTheme(named: a.name, isDark: false, appearanceIsDark: true)
        #expect(lightSlot == a.name)
        #expect(on(g, session))
    }

    @Test func setGlobalThemeLeavesOverridingSessionsAlone() throws {
        let store = makeStore()
        let following = try #require(store.sessions.first)
        let overriding = try #require(store.addSession())
        overriding.themeOverride = .both(b.name)
        store.applyTerminalTheme(b, to: overriding)
        store.setGlobalTheme(named: a.name, isDark: true, appearanceIsDark: true)
        #expect(on(a, following))
        #expect(on(b, overriding))
    }

    @Test func setGlobalThemeWithEmptyNamePersistsWithoutApplying() throws {
        let store = makeStore()
        let session = try #require(store.sessions.first)
        store.applyTerminalTheme(g, to: session)
        store.setGlobalTheme(named: "", isDark: true, appearanceIsDark: true)
        #expect(darkSlot == "")
        #expect(on(g, session))
    }

    // MARK: - Global preview

    @Test func endingGlobalPreviewRestoresTheCommittedTheme() throws {
        let store = makeStore()
        let session = try #require(store.sessions.first)
        store.setGlobalTheme(named: a.name, isDark: true, appearanceIsDark: true)
        store.previewGlobalTheme(b, isDark: true)
        #expect(on(b, session))
        #expect(darkSlot == a.name)
        store.endGlobalThemePreview(isDark: true)
        #expect(on(a, session))
        #expect(darkSlot == a.name)
    }

    @Test func endingGlobalPreviewAfterCommitKeepsTheCommittedTheme() throws {
        let store = makeStore()
        let session = try #require(store.sessions.first)
        store.previewGlobalTheme(b, isDark: true)
        store.setGlobalTheme(named: b.name, isDark: true, appearanceIsDark: true)
        store.endGlobalThemePreview(isDark: true)
        #expect(on(b, session))
        #expect(darkSlot == b.name)
    }

    @Test func previewAfterCommitThenCancelRestoresTheLatestCommit() throws {
        let store = makeStore()
        let session = try #require(store.sessions.first)
        store.previewGlobalTheme(b, isDark: true)
        store.setGlobalTheme(named: b.name, isDark: true, appearanceIsDark: true)
        store.previewGlobalTheme(a, isDark: true)
        store.endGlobalThemePreview(isDark: true)
        #expect(on(b, session))
    }

    @Test func endingGlobalPreviewWithNothingPendingDoesNothing() throws {
        let store = makeStore()
        let session = try #require(store.sessions.first)
        store.setGlobalTheme(named: a.name, isDark: true, appearanceIsDark: true)
        store.applyTerminalTheme(b, to: session)
        store.endGlobalThemePreview(isDark: true)
        #expect(on(b, session))
    }

    // MARK: - Session preview

    @Test func endingSessionPreviewRestoresTheSessionTheme() throws {
        let store = makeStore()
        let window = try #require(store.windows.first)
        let session = try #require(window.sessions.first)
        session.themeOverride = .both(a.name)
        store.applyTerminalTheme(a, to: session)
        store.previewSessionTheme(b, for: session)
        #expect(on(b, session))
        store.endSessionThemePreviews(in: window, isDark: true)
        #expect(on(a, session))
        #expect(session.themeOverride == .both(a.name))
    }

    @Test func endingSessionPreviewRestoresGlobalForAFollowingSession() throws {
        let store = makeStore()
        let window = try #require(store.windows.first)
        let session = try #require(window.sessions.first)
        store.applyTerminalTheme(g, to: session)
        store.previewSessionTheme(b, for: session)
        store.endSessionThemePreviews(in: window, isDark: true)
        #expect(on(g, session))
        #expect(session.themeOverride == nil)
    }

    @Test func confirmingSessionThemeKeepsItAfterEndingPreviews() throws {
        let store = makeStore()
        let window = try #require(store.windows.first)
        let session = try #require(window.sessions.first)
        store.applyTerminalTheme(g, to: session)
        store.previewSessionTheme(b, for: session)
        store.setSessionTheme(b, for: session)
        store.endSessionThemePreviews(in: window, isDark: true)
        #expect(on(b, session))
        #expect(session.themeOverride == .both(b.name))
    }

    @Test func endingSessionPreviewsOnlyTouchesThatWindow() throws {
        let store = makeStore()
        let w1 = try #require(store.windows.first)
        let w2 = store.openWindowRuntime(for: WindowID())
        let s1 = try #require(w1.sessions.first)
        let s2 = try #require(w2.sessions.first)
        store.applyTerminalTheme(g, to: s1)
        store.applyTerminalTheme(g, to: s2)
        store.previewSessionTheme(b, for: s1)
        store.previewSessionTheme(b, for: s2)
        store.endSessionThemePreviews(in: w1, isDark: true)
        #expect(on(g, s1))
        #expect(on(b, s2))
        #expect(store.sessionThemePreviewNames[s2.id] == b.name)
        store.endSessionThemePreviews(in: w2, isDark: true)
        #expect(on(g, s2))
        #expect(store.sessionThemePreviewNames.isEmpty)
    }
}
