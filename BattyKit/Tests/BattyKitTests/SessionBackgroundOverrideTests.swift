// SessionBackgroundOverrideTests.swift

import Foundation
import GhosttyTerminal
import Testing
@testable import BattyKit

private nonisolated final class ChangeFlag: @unchecked Sendable {
    var fired = false
}

@MainActor
final class SessionBackgroundOverrideTests {
    private static let panePath = "/tmp/batty-session-background-tests/pane.png"
    private static let sessionPath = "/tmp/batty-session-background-tests/session.png"
    private static let appWidePath = "/tmp/batty-session-background-tests/app-wide.png"

    private static let paneValue = TerminalBackgroundSettings(
        imagePath: panePath, fit: .none, position: .topLeft, imageOpacity: 0.35, terminalOpacity: 0.5
    )
    private static let sessionValue = TerminalBackgroundSettings(
        imagePath: sessionPath, fit: .contain, position: .bottomCenter, imageOpacity: 0.55, terminalOpacity: 0.7, opacityAffectsCells: true
    )
    private static let paneLines = [
        "background-image = \"\(panePath)\"",
        "background-image-fit = none",
        "background-image-position = top-left",
        "background-image-opacity = 0.35",
        "background-opacity = 0.5",
    ]
    private static let sessionLines = [
        "background-image = \"\(sessionPath)\"",
        "background-image-fit = contain",
        "background-image-position = bottom-center",
        "background-image-opacity = 0.55",
        "background-opacity = 0.7",
        "background-opacity-cells = true",
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

    private var gate: AppWideBackgroundGate { .acceptingEveryImage(defaults: defaults) }

    private var appWide: TerminalBackgroundSettings { SettingsPreference.resolvedBackground(defaults: defaults) }

    private func pane(tabCount: Int = 1) -> PaneRuntime {
        PaneRuntime(tabs: (0..<tabCount).map { _ in TabRuntime(backgroundGate: gate) }, tabBackgroundGate: gate)
    }

    private func session(_ first: PaneRuntime, _ second: PaneRuntime) -> SessionRuntime {
        SessionRuntime(tree: SplitTree(root: .split(id: UUID(), direction: .horizontal, ratio: SplitRatio(0.5), left: .leaf(first), right: .leaf(second))))
    }

    private func session(_ pane: PaneRuntime? = nil) -> SessionRuntime {
        SessionRuntime(tree: SplitTree(root: .leaf(pane ?? self.pane())))
    }

    private func store(_ sessions: [SessionRuntime]) -> AppStateStore {
        AppStateStore(sessions: sessions, preferences: defaults, backgroundGate: gate)
    }

    private func lines(_ tab: TabRuntime) -> [String] {
        tab.terminal.renderedConfig.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private func backgroundLines(_ tab: TabRuntime) -> [String] {
        lines(tab).filter { $0.hasPrefix("background-") }
    }

    // MARK: - Resolution

    @Test func effectivePaneBeatsSessionBeatsAppWide() {
        #expect(TerminalBackgroundSettings.effective(tab: nil, pane: Self.paneValue, session: Self.sessionValue, appWide: .off) == Self.paneValue)
    }

    @Test func effectiveSessionBeatsAppWide() {
        let wide = TerminalBackgroundSettings(imagePath: Self.appWidePath)
        #expect(TerminalBackgroundSettings.effective(tab: nil, pane: nil, session: Self.sessionValue, appWide: wide) == Self.sessionValue)
    }

    @Test func effectiveFallsThroughToAppWide() {
        let wide = TerminalBackgroundSettings(imagePath: Self.appWidePath)
        #expect(TerminalBackgroundSettings.effective(tab: nil, pane: nil, session: nil, appWide: wide) == wide)
    }

    // MARK: - Fan-out

    @Test func settingOverrideReachesEveryTabInEveryTerminalPane() {
        let first = pane(tabCount: 2)
        let second = pane(tabCount: 2)
        session(first, second).setBackgroundOverride(Self.sessionValue)
        for tab in first.tabs + second.tabs {
            #expect(backgroundLines(tab) == Self.sessionLines)
        }
    }

    @Test func settingOverrideReachesAnUnselectedSession() throws {
        let pane = pane()
        let unselected = session(pane)
        let selected = session()
        let store = store([unselected, selected])
        let window = try #require(store.windows.first)
        window.setSelectedSession(id: selected.id)
        unselected.setBackgroundOverride(Self.sessionValue)
        #expect(window.selectedSessionID == selected.id)
        #expect(backgroundLines(pane.tabs[0]) == Self.sessionLines)
    }

    @Test func overrideDoesNotReachAnotherSession() {
        configureAppWide()
        let other = pane()
        let otherSession = session(other)
        session().setBackgroundOverride(Self.sessionValue)
        #expect(otherSession.backgroundOverride == nil)
        #expect(other.sessionBackgroundOverride == nil)
        #expect(backgroundLines(other.tabs[0]) == Self.appWideLines)
    }

    @Test func overrideSkipsAPaneWithItsOwnOverride() {
        configureAppWide()
        let own = pane()
        let following = pane()
        let session = session(own, following)
        own.setBackgroundOverride(Self.paneValue)
        session.setBackgroundOverride(Self.sessionValue)
        #expect(backgroundLines(own.tabs[0]) == Self.paneLines)
        #expect(backgroundLines(following.tabs[0]) == Self.sessionLines)
    }

    @Test func clearingAPaneOverrideFallsToTheSession() {
        configureAppWide()
        let pane = pane()
        let session = session(pane)
        pane.setBackgroundOverride(Self.paneValue)
        session.setBackgroundOverride(Self.sessionValue)
        pane.setBackgroundOverride(nil)
        #expect(backgroundLines(pane.tabs[0]) == Self.sessionLines)
    }

    @Test func clearingTheSessionOverrideReturnsFollowingPanesToAppWideAndKeepsAPaneOverride() {
        configureAppWide()
        let own = pane()
        let following = pane()
        let session = session(own, following)
        own.setBackgroundOverride(Self.paneValue)
        session.setBackgroundOverride(Self.sessionValue)
        session.setBackgroundOverride(nil)
        #expect(backgroundLines(own.tabs[0]) == Self.paneLines)
        #expect(backgroundLines(following.tabs[0]) == Self.appWideLines)
    }

    @Test func noImageSessionOverrideHidesAppWideImage() {
        configureAppWide()
        let pane = pane()
        session(pane).setBackgroundOverride(appWide.withImagePath(nil))
        #expect(!pane.tabs[0].terminal.renderedConfig.contains("background-image = "))
        #expect(lines(pane.tabs[0]).contains("background-opacity = 0.6"))
    }

    @Test func sessionFanOutKeepsPerTabLines() {
        let tab = TabRuntime(command: "/bin/cat", backgroundGate: gate)
        let pane = PaneRuntime(tabs: [tab], tabBackgroundGate: gate)
        let session = session(pane)
        session.setBackgroundOverride(Self.sessionValue)
        let rendered = lines(tab)
        #expect(backgroundLines(tab) == Self.sessionLines)
        for expected in [
            "keybind = clear",
            "copy-on-select = false",
            "command = /bin/cat",
            "wait-after-command = true",
            "env = BATTY_TAB_ID=\(tab.id.uuidString)",
            "env = BATTY_PANE_ID=\(pane.id.uuidString)",
            "env = BATTY_SESSION_ID=\(session.id.uuidString)",
        ] {
            #expect(rendered.contains(expected), "missing \(expected)")
        }
    }

    @Test func nonTerminalPaneIgnoresSessionOverride() {
        let pane = PaneRuntime(kind: .systemMetrics, tabBackgroundGate: gate, contentFactory: { _ in nil })
        let session = session(pane)
        let before = pane.tabs[0].terminal.renderedConfig
        session.setBackgroundOverride(Self.sessionValue)
        #expect(pane.sessionBackgroundOverride == nil)
        #expect(pane.tabs[0].terminal.renderedConfig == before)
    }

    @Test func settingAnEqualOverrideDoesNotNotify() {
        let session = session()
        session.setBackgroundOverride(Self.sessionValue)
        let changed = ChangeFlag()
        withObservationTracking { _ = session.backgroundOverride } onChange: { changed.fired = true }
        session.setBackgroundOverride(Self.sessionValue)
        #expect(!changed.fired)
        session.setBackgroundOverride(nil)
        #expect(changed.fired)
    }

    @Test func settingAnEqualSessionOverrideOnAPaneDoesNotNotify() {
        let pane = pane()
        pane.setSessionBackgroundOverride(Self.sessionValue)
        let changed = ChangeFlag()
        withObservationTracking { _ = pane.sessionBackgroundOverride } onChange: { changed.fired = true }
        pane.setSessionBackgroundOverride(Self.sessionValue)
        #expect(!changed.fired)
        pane.setSessionBackgroundOverride(nil)
        #expect(changed.fired)
    }

    // MARK: - New Tabs and Panes

    @Test func newTabInOverriddenSessionCarriesTheBackground() {
        configureAppWide()
        let pane = pane()
        session(pane).setBackgroundOverride(Self.sessionValue)
        #expect(backgroundLines(pane.addTab()) == Self.sessionLines)
    }

    @Test func newTabInAPaneWithItsOwnOverrideCarriesThePaneBackground() {
        configureAppWide()
        let pane = pane()
        let session = session(pane)
        session.setBackgroundOverride(Self.sessionValue)
        pane.setBackgroundOverride(Self.paneValue)
        let tab = pane.addTab()
        #expect(backgroundLines(tab) == Self.paneLines)
        pane.setBackgroundOverride(nil)
        #expect(backgroundLines(tab) == Self.sessionLines)
    }

    @Test func splitFocusedPaneInheritsTheSessionOverride() {
        let session = session()
        session.setBackgroundOverride(Self.sessionValue)
        let child = session.tree.splitFocusedPane(direction: .horizontal)
        #expect(child.sessionBackgroundOverride == Self.sessionValue)
        #expect(backgroundLines(child.tabs[0]) == Self.sessionLines)
    }

    @Test func splitFullDimensionInheritsTheSessionOverride() {
        let session = session()
        session.setBackgroundOverride(Self.sessionValue)
        let child = session.tree.splitFullDimension(direction: .vertical)
        #expect(child.sessionBackgroundOverride == Self.sessionValue)
        #expect(backgroundLines(child.tabs[0]) == Self.sessionLines)
    }

    @Test func splitPaneInheritsTheSessionOverride() throws {
        let pane = pane()
        let session = session(pane)
        session.setBackgroundOverride(Self.sessionValue)
        let child = try #require(session.tree.splitPane(id: pane.id, direction: .horizontal, isSessionSelected: true))
        #expect(child.sessionBackgroundOverride == Self.sessionValue)
        #expect(backgroundLines(child.tabs[0]) == Self.sessionLines)
    }

    @Test func splitOfAPaneWithItsOwnOverrideTakesTheSessionNotThePane() {
        let parent = pane()
        let session = session(parent)
        session.setBackgroundOverride(Self.sessionValue)
        parent.setBackgroundOverride(Self.paneValue)
        let child = session.tree.splitFocusedPane(direction: .horizontal, inheritingFrom: parent)
        #expect(child.backgroundOverride == nil)
        #expect(backgroundLines(child.tabs[0]) == Self.sessionLines)
    }

    @Test func newPaneFollowsAfterTheSessionOverrideIsCleared() {
        let session = session()
        session.setBackgroundOverride(Self.sessionValue)
        session.setBackgroundOverride(nil)
        let child = session.tree.splitFocusedPane(direction: .horizontal)
        #expect(child.sessionBackgroundOverride == nil)
        #expect(!child.tabs[0].terminal.renderedConfig.contains(Self.sessionPath))
    }

    @Test func overrideSetBeforeJoiningAWindowReachesExistingTabs() {
        let pane = pane(tabCount: 2)
        let session = session(pane)
        session.setBackgroundOverride(Self.sessionValue)
        _ = store([session])
        #expect(session.backgroundOverride == Self.sessionValue)
        for tab in pane.tabs {
            #expect(backgroundLines(tab) == Self.sessionLines)
        }
    }

    @Test func duplicateSessionDoesNotCopyTheOverride() throws {
        let source = session()
        let store = store([source])
        source.setBackgroundOverride(Self.sessionValue)
        let window = try #require(store.windows.first)
        let copy = try #require(window.duplicateSession(id: source.id))
        #expect(copy.backgroundOverride == nil)
        #expect(copy.tree.allPanes.allSatisfy { $0.sessionBackgroundOverride == nil })
    }

    // MARK: - App-wide changes

    @Test func appWidePushSkipsASessionWithAnOverride() {
        let pane = pane()
        let session = session(pane)
        let store = store([session])
        session.setBackgroundOverride(Self.sessionValue)
        configureAppWide()
        store.applyAppWideBackgroundToAllSurfaces()
        #expect(backgroundLines(pane.tabs[0]) == Self.sessionLines)
    }

    @Test func appWidePushStillReachesAFollowingSessionBesideIt() {
        let overridden = session()
        let following = pane()
        let store = store([overridden, session(following)])
        overridden.setBackgroundOverride(Self.sessionValue)
        configureAppWide()
        store.applyAppWideBackgroundToAllSurfaces()
        #expect(backgroundLines(following.tabs[0]) == Self.appWideLines)
    }

    @Test func clearingAfterAnAppWideChangeTakesTheLatestValue() {
        let pane = pane()
        let session = session(pane)
        let store = store([session])
        session.setBackgroundOverride(Self.sessionValue)
        configureAppWide()
        store.applyAppWideBackgroundToAllSurfaces()
        session.setBackgroundOverride(nil)
        #expect(backgroundLines(pane.tabs[0]) == Self.appWideLines)
    }

    @Test func appearanceChangeKeepsSessionOverride() {
        configureAppWide()
        let pane = pane()
        let session = session(pane)
        let store = store([session])
        session.setBackgroundOverride(Self.sessionValue)
        defaults.set(21.0, forKey: SettingsPreference.fontSizeKey)
        store.applyAppearanceToAllSurfaces()
        #expect(backgroundLines(pane.tabs[0]) == Self.sessionLines)
        #expect(lines(pane.tabs[0]).contains("font-size = 21"))
    }

    @Test func appearanceChangeKeepsPaneOverrideInAnOverriddenSession() {
        configureAppWide()
        let own = pane()
        let following = pane()
        let session = session(own, following)
        let store = store([session])
        session.setBackgroundOverride(Self.sessionValue)
        own.setBackgroundOverride(Self.paneValue)
        store.applyAppearanceToAllSurfaces()
        #expect(backgroundLines(own.tabs[0]) == Self.paneLines)
        #expect(backgroundLines(following.tabs[0]) == Self.sessionLines)
    }

    // MARK: - Editor

    private func editor(for target: any BackgroundOverrideHolder) -> BackgroundOverrideEditor {
        BackgroundOverrideEditor(target: target, appWide: appWide, originalOverride: target.backgroundOverride)
    }

    @Test func sessionEditorCustomSeedsFromAppWide() {
        configureAppWide()
        let pane = pane()
        let session = session(pane)
        editor(for: session).selectCustom()
        #expect(session.backgroundOverride == appWide)
        #expect(backgroundLines(pane.tabs[0]) == Self.appWideLines)
    }

    @Test func sessionEditorCancelRestoresTheOriginalOverride() {
        let session = session()
        session.setBackgroundOverride(Self.sessionValue)
        let editor = editor(for: session)
        editor.update { $0.withTerminalOpacity(0.25) }
        #expect(session.backgroundOverride != Self.sessionValue)
        editor.selectFollow()
        editor.cancel()
        #expect(session.backgroundOverride == Self.sessionValue)
    }

    @Test func sessionEditorFollowClearsTheOverride() {
        let session = session()
        session.setBackgroundOverride(Self.sessionValue)
        editor(for: session).selectFollow()
        #expect(session.backgroundOverride == nil)
    }

    @Test func sessionEditorUpdateIsIgnoredWhileFollowing() {
        let session = session()
        editor(for: session).update { $0.pickingImage(path: Self.sessionPath) }
        #expect(session.backgroundOverride == nil)
    }

    @Test func paneEditorFollowingShowsTheSessionValue() {
        configureAppWide()
        let pane = pane()
        session(pane).setBackgroundOverride(Self.sessionValue)
        let editor = editor(for: pane)
        #expect(editor.isFollowing)
        #expect(editor.current == Self.sessionValue)
    }

    @Test func paneEditorCustomSeedsFromTheSession() {
        configureAppWide()
        let pane = pane()
        session(pane).setBackgroundOverride(Self.sessionValue)
        editor(for: pane).selectCustom()
        #expect(pane.backgroundOverride == Self.sessionValue)
    }

    @Test func paneEditorFollowReturnsToTheSessionNotAppWide() {
        configureAppWide()
        let pane = pane()
        session(pane).setBackgroundOverride(Self.sessionValue)
        pane.setBackgroundOverride(Self.paneValue)
        editor(for: pane).selectFollow()
        #expect(pane.backgroundOverride == nil)
        #expect(backgroundLines(pane.tabs[0]) == Self.sessionLines)
    }

    @Test func paneScopeFollowTitleNamesTheSessionOnlyWhenItHasAnOverride() {
        let pane = pane()
        let session = session(pane)
        #expect(BackgroundOverrideScope.pane(pane).followTitle == "Follow App Default")
        session.setBackgroundOverride(Self.sessionValue)
        #expect(BackgroundOverrideScope.pane(pane).followTitle == "Follow Session")
        #expect(BackgroundOverrideScope.pane(pane).identifierPrefix == "pane-background-sheet")
    }

    @Test func sessionSheetNotesNarrowerLevels() {
        let pane = pane()
        let session = session(pane)
        #expect(session.narrowerLevelsNote == nil)
        #expect(session.effectiveBackground(appWide: appWide).source == .settings)
        pane.tabs[0].setBackgroundOverride(Self.paneValue)
        #expect(session.narrowerLevelsNote != nil)
        pane.tabs[0].setBackgroundOverride(nil)
        pane.setBackgroundOverride(Self.paneValue)
        #expect(session.narrowerLevelsNote != nil)
    }
}
