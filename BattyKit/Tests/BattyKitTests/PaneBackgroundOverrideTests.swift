// PaneBackgroundOverrideTests.swift

import Foundation
import GhosttyTerminal
import Testing
@testable import BattyKit

private nonisolated final class ChangeFlag: @unchecked Sendable {
    var fired = false
}

@MainActor
final class PaneBackgroundOverrideTests {
    private static let customPath = "/tmp/batty-pane-background-tests/custom.png"
    private static let appWidePath = "/tmp/batty-pane-background-tests/app-wide.png"
    private static let custom = TerminalBackgroundSettings(
        imagePath: customPath, fit: .cover, position: .topLeft, imageOpacity: 0.35, terminalOpacity: 0.5
    )
    private static let customLines = [
        "background-image = \"\(customPath)\"",
        "background-image-fit = cover",
        "background-image-position = top-left",
        "background-image-opacity = 0.35",
        "background-opacity = 0.5",
    ]
    private static let appWideLines = [
        "background-image = \"\(appWidePath)\"",
        "background-image-fit = stretch",
        "background-image-position = bottom-right",
        "background-image-opacity = 0.8",
        "background-opacity = 0.6",
    ]

    private let testDefaults = TestDefaults()
    private var defaults: UserDefaults { testDefaults.defaults }

    @MainActor deinit { testDefaults.tearDown() }

    private func configureAppWide() {
        defaults.set(Self.appWidePath, forKey: SettingsPreference.backgroundImagePathKey)
        defaults.set("stretch", forKey: SettingsPreference.backgroundImageFitKey)
        defaults.set("bottom-right", forKey: SettingsPreference.backgroundImagePositionKey)
        defaults.set(0.8, forKey: SettingsPreference.backgroundImageOpacityKey)
        defaults.set(0.6, forKey: SettingsPreference.backgroundOpacityKey)
    }

    private var appWide: TerminalBackgroundSettings { SettingsPreference.resolvedBackground(defaults: defaults) }

    private func pane(tabCount: Int = 1) -> PaneRuntime {
        PaneRuntime(tabs: (0..<tabCount).map { _ in TabRuntime(preferences: defaults) }, tabPreferences: defaults)
    }

    private func lines(_ tab: TabRuntime) -> [String] {
        tab.terminal.renderedConfig.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private func backgroundLines(_ tab: TabRuntime) -> [String] {
        lines(tab).filter { $0.hasPrefix("background-") }
    }

    /// A store whose first Session is split, so it has two terminal Panes.
    private func storeWithTwoPanes() throws -> (AppStateStore, PaneRuntime, PaneRuntime) {
        let store = AppStateStore(preferences: defaults)
        let session = try #require(store.windows.first?.sessions.first)
        let first = try #require(session.tree.allPanes.first)
        let second = session.tree.splitFocusedPane(direction: .horizontal)
        return (store, first, second)
    }

    // MARK: - Fan-out and inheritance

    @Test func settingOverrideReachesEveryTabInThePane() {
        let pane = pane(tabCount: 2)
        #expect(pane.activeTabID == pane.tabs[0].id)
        pane.setBackgroundOverride(Self.custom)
        for tab in pane.tabs {
            #expect(backgroundLines(tab) == Self.customLines)
        }
    }

    @Test func newTabInOverriddenPaneCarriesTheBackground() {
        let pane = pane()
        pane.attachToSession(UUID())
        pane.setBackgroundOverride(Self.custom)
        let tab = pane.addTab()
        #expect(backgroundLines(tab) == Self.customLines)
    }

    @Test func newTabBeforeSessionAttachCarriesTheBackground() {
        let pane = pane()
        pane.setBackgroundOverride(Self.custom)
        let tab = pane.addTab()
        #expect(backgroundLines(tab) == Self.customLines)
    }

    @Test func attachContextKeepsTheOverride() {
        let pane = pane()
        pane.setBackgroundOverride(Self.custom)
        pane.attachToSession(UUID())
        #expect(backgroundLines(pane.tabs[0]) == Self.customLines)
    }

    @Test func newTabInFollowingPaneUsesAppWide() {
        configureAppWide()
        let tab = pane().addTab()
        #expect(backgroundLines(tab) == Self.appWideLines)
    }

    @Test func overrideDoesNotReachASiblingPane() {
        let pane = pane()
        let sibling = self.pane()
        pane.setBackgroundOverride(Self.custom)
        #expect(sibling.backgroundOverride == nil)
        #expect(backgroundLines(sibling.tabs[0]).isEmpty)
    }

    @Test func splitPaneFollowsRatherThanInherits() throws {
        let (store, _, _) = try storeWithTwoPanes()
        let session = try #require(store.windows.first?.sessions.first)
        let parent = try #require(session.tree.allPanes.first)
        parent.setBackgroundOverride(Self.custom)
        let child = session.tree.splitFocusedPane(direction: .vertical, inheritingFrom: parent)
        #expect(child.backgroundOverride == nil)
        #expect(!child.tabs[0].terminal.renderedConfig.contains(Self.customPath))
    }

    @Test func nonTerminalPaneIgnoresOverride() {
        let pane = PaneRuntime(kind: .systemMetrics, tabPreferences: defaults, contentFactory: { _ in nil })
        let before = pane.tabs[0].terminal.renderedConfig
        pane.setBackgroundOverride(Self.custom)
        #expect(pane.backgroundOverride == nil)
        #expect(pane.tabs[0].terminal.renderedConfig == before)
    }

    // MARK: - Follow and clear

    @Test func clearingOverrideReturnsEveryTabToAppWide() {
        configureAppWide()
        let pane = pane(tabCount: 2)
        pane.setBackgroundOverride(Self.custom)
        pane.setBackgroundOverride(nil)
        for tab in pane.tabs {
            #expect(backgroundLines(tab) == Self.appWideLines)
        }
    }

    @Test func clearingOverrideWithNoAppWideEmitsNothing() {
        let pane = pane()
        pane.setBackgroundOverride(Self.custom)
        pane.setBackgroundOverride(nil)
        #expect(backgroundLines(pane.tabs[0]).isEmpty)
    }

    @Test func noImageOverrideHidesAppWideImage() {
        configureAppWide()
        let pane = pane()
        pane.setBackgroundOverride(appWide.withImagePath(nil))
        #expect(!pane.tabs[0].terminal.renderedConfig.contains("background-image = "))
        #expect(lines(pane.tabs[0]).contains("background-opacity = 0.6"))
    }

    @Test func settingAnEqualOverrideDoesNotNotify() {
        let pane = pane()
        pane.setBackgroundOverride(Self.custom)
        let equal = ChangeFlag()
        withObservationTracking { _ = pane.backgroundOverride } onChange: { equal.fired = true }
        pane.setBackgroundOverride(Self.custom)
        #expect(!equal.fired)
        pane.setBackgroundOverride(nil)
        #expect(equal.fired)
    }

    // MARK: - The replace hazard

    @Test func paneFanOutKeepsPerTabLines() {
        let tab = TabRuntime(command: "/bin/cat", preferences: defaults)
        let pane = PaneRuntime(tabs: [tab], tabPreferences: defaults)
        let sessionID = UUID()
        pane.attachToSession(sessionID)
        pane.setBackgroundOverride(Self.custom)
        let rendered = lines(tab)
        #expect(backgroundLines(tab) == Self.customLines)
        for expected in [
            "keybind = clear",
            "copy-on-select = false",
            "command = /bin/cat",
            "wait-after-command = true",
            "env = BATTY_TAB_ID=\(tab.id.uuidString)",
            "env = BATTY_PANE_ID=\(pane.id.uuidString)",
            "env = BATTY_SESSION_ID=\(sessionID.uuidString)",
        ] {
            #expect(rendered.contains(expected), "missing \(expected)")
        }
    }

    @Test func appearanceChangeKeepsPaneOverride() throws {
        let (store, overridden, following) = try storeWithTwoPanes()
        overridden.setBackgroundOverride(Self.custom)
        defaults.set(21.0, forKey: SettingsPreference.fontSizeKey)
        store.applyAppearanceToAllSurfaces()
        #expect(backgroundLines(overridden.tabs[0]) == Self.customLines)
        #expect(lines(overridden.tabs[0]).contains("font-size = 21"))
        #expect(backgroundLines(following.tabs[0]).isEmpty)
        #expect(lines(following.tabs[0]).contains("font-size = 21"))
    }

    @Test func followingPaneTakesLaterAppWideChange() throws {
        let (store, _, following) = try storeWithTwoPanes()
        configureAppWide()
        store.applyAppearanceToAllSurfaces()
        #expect(backgroundLines(following.tabs[0]) == Self.appWideLines)
    }

    @Test func overriddenPaneIgnoresLaterAppWideChange() throws {
        let (store, overridden, _) = try storeWithTwoPanes()
        overridden.setBackgroundOverride(Self.custom)
        configureAppWide()
        store.applyAppearanceToAllSurfaces()
        #expect(backgroundLines(overridden.tabs[0]) == Self.customLines)
    }

    // MARK: - Resolution and editing

    @Test func effectivePrefersThePaneOverride() {
        #expect(TerminalBackgroundSettings.effective(pane: Self.custom, appWide: .off) == Self.custom)
    }

    @Test func effectiveFallsThroughToAppWide() {
        #expect(TerminalBackgroundSettings.effective(pane: nil, appWide: Self.custom) == Self.custom)
    }

    @Test func pickingFirstImageAppliesTheTint() {
        let picked = TerminalBackgroundSettings(imagePath: nil, imageOpacity: 0.9).pickingImage(path: Self.customPath)
        #expect(picked.imagePath == Self.customPath)
        #expect(picked.imageOpacity == TerminalBackgroundSettings.firstImageOpacity)
    }

    @Test func replacingAnImageKeepsItsOpacity() {
        let picked = TerminalBackgroundSettings(imagePath: Self.appWidePath, imageOpacity: 0.9).pickingImage(path: Self.customPath)
        #expect(picked.imagePath == Self.customPath)
        #expect(picked.imageOpacity == 0.9)
    }

    private func editor(for pane: PaneRuntime) -> PaneBackgroundEditor {
        PaneBackgroundEditor(pane: pane, appWide: appWide, originalOverride: pane.backgroundOverride)
    }

    @Test func editorCustomSeedsFromEffectiveValue() {
        configureAppWide()
        let pane = pane()
        editor(for: pane).selectCustom()
        #expect(pane.backgroundOverride == appWide)
        #expect(backgroundLines(pane.tabs[0]) == Self.appWideLines)
    }

    @Test func editorCancelRestoresTheOriginalOverride() {
        let followingPane = pane()
        let followingEditor = editor(for: followingPane)
        followingEditor.selectCustom()
        followingEditor.update { $0.withTerminalOpacity(0.25) }
        followingEditor.cancel()
        #expect(followingPane.backgroundOverride == nil)

        let customPane = pane()
        customPane.setBackgroundOverride(Self.custom)
        let customEditor = editor(for: customPane)
        customEditor.update { $0.withTerminalOpacity(0.25) }
        customEditor.selectFollow()
        customEditor.cancel()
        #expect(customPane.backgroundOverride == Self.custom)
    }

    @Test func editorFollowClearsTheOverride() {
        let pane = pane()
        pane.setBackgroundOverride(Self.custom)
        editor(for: pane).selectFollow()
        #expect(pane.backgroundOverride == nil)
    }

    @Test func editorUpdateIsIgnoredWhileFollowing() {
        let pane = pane()
        editor(for: pane).update { $0.pickingImage(path: Self.customPath) }
        #expect(pane.backgroundOverride == nil)
    }
}
