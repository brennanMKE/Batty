// TabBackgroundOverrideTests.swift

import Foundation
import GhosttyTerminal
import Testing
@testable import BattyKit

private nonisolated final class ChangeFlag: @unchecked Sendable {
    var fired = false
}

@MainActor
final class TabBackgroundOverrideTests {
    private static let tabPath = "/tmp/batty-tab-background-tests/tab.png"
    private static let panePath = "/tmp/batty-tab-background-tests/pane.png"
    private static let appWidePath = "/tmp/batty-tab-background-tests/app-wide.png"
    private static let tabValue = TerminalBackgroundSettings(
        imagePath: tabPath, fit: .contain, position: .topLeft, imageOpacity: 0.35, terminalOpacity: 0.5
    )
    private static let paneValue = TerminalBackgroundSettings(
        imagePath: panePath, fit: .stretch, position: .bottomLeft, imageOpacity: 0.8, terminalOpacity: 0.45
    )
    private static let sessionValue = TerminalBackgroundSettings(imagePath: nil, terminalOpacity: 0.7)

    private let testDefaults = TestDefaults()
    private var defaults: UserDefaults { testDefaults.defaults }

    @MainActor deinit { testDefaults.tearDown() }

    private func configureAppWide() {
        defaults.set(Self.appWidePath, forKey: SettingsPreference.backgroundImagePathKey)
        defaults.set(0.6, forKey: SettingsPreference.backgroundOpacityKey)
    }

    private var gate: AppWideBackgroundGate { .acceptingEveryImage(defaults: defaults) }

    private var appWide: TerminalBackgroundSettings { SettingsPreference.resolvedBackground(defaults: defaults) }

    private func pane(tabCount: Int = 2) -> PaneRuntime {
        PaneRuntime(tabs: (0..<tabCount).map { _ in TabRuntime(backgroundGate: gate) }, tabBackgroundGate: gate)
    }

    private func store(_ pane: PaneRuntime) -> (AppStateStore, SessionRuntime) {
        let session = SessionRuntime(tree: SplitTree(root: .leaf(pane)))
        return (AppStateStore(sessions: [session], preferences: defaults, backgroundGate: gate), session)
    }

    private func backgroundLines(_ tab: TabRuntime) -> [String] {
        tab.terminal.renderedConfig.split(separator: "\n").map(String.init).filter { $0.hasPrefix("background-") }
    }

    private func imageLine(_ tab: TabRuntime) -> String? {
        backgroundLines(tab).first { $0.hasPrefix("background-image = ") }
    }

    private func paneEditor(_ pane: PaneRuntime) -> BackgroundOverrideEditor {
        BackgroundOverrideEditor(target: pane, appWide: appWide, originalOverride: pane.backgroundOverride, replacedOverrides: pane.replacedOverrides())
    }

    // MARK: - Chain

    @Test func effectivePrefersTheTabOverride() {
        #expect(TerminalBackgroundSettings.effective(tab: Self.tabValue, pane: Self.paneValue, session: Self.sessionValue, appWide: .off) == Self.tabValue)
        #expect(TerminalBackgroundSettings.effective(tab: nil, pane: Self.paneValue, session: Self.sessionValue, appWide: .off) == Self.paneValue)
    }

    @Test func tabOverrideRendersForThatTabOnly() {
        let pane = pane()
        pane.tabs[0].setBackgroundOverride(Self.tabValue)
        #expect(imageLine(pane.tabs[0]) == "background-image = \"\(Self.tabPath)\"")
        #expect(backgroundLines(pane.tabs[1]).isEmpty)
    }

    @Test func tabOverrideBeatsPaneSessionAndAppWide() {
        configureAppWide()
        let pane = pane()
        let (_, session) = store(pane)
        session.setBackgroundOverride(Self.sessionValue)
        pane.setBackgroundOverride(Self.paneValue)
        pane.tabs[0].setBackgroundOverride(Self.tabValue)
        #expect(imageLine(pane.tabs[0]) == "background-image = \"\(Self.tabPath)\"")
        #expect(imageLine(pane.tabs[1]) == "background-image = \"\(Self.panePath)\"")
    }

    @Test func clearingTabOverrideFallsBackToPane() {
        let pane = pane()
        pane.setBackgroundOverride(Self.paneValue)
        pane.tabs[0].setBackgroundOverride(Self.tabValue)
        pane.tabs[0].setBackgroundOverride(nil)
        #expect(imageLine(pane.tabs[0]) == "background-image = \"\(Self.panePath)\"")
    }

    @Test func settingAnEqualTabOverrideDoesNotNotify() {
        let tab = pane().tabs[0]
        tab.setBackgroundOverride(Self.tabValue)
        let flag = ChangeFlag()
        withObservationTracking { _ = tab.backgroundOverride } onChange: { flag.fired = true }
        tab.setBackgroundOverride(Self.tabValue)
        #expect(!flag.fired)
    }

    // MARK: - The Pane gear replaces Tab values

    @Test func paneOverrideClearsEveryTabsOwnValue() {
        let pane = pane()
        pane.tabs[0].setBackgroundOverride(Self.tabValue)
        pane.tabs[1].setBackgroundOverride(Self.tabValue)
        pane.setBackgroundOverride(Self.paneValue)
        #expect(pane.tabs.allSatisfy { $0.backgroundOverride == nil })
        for tab in pane.tabs { #expect(imageLine(tab) == "background-image = \"\(Self.panePath)\"") }
    }

    @Test func paneFollowAlreadySelectedStillClearsTabValues() {
        let pane = pane()
        pane.tabs[0].setBackgroundOverride(Self.tabValue)
        #expect(pane.backgroundOverride == nil)
        paneEditor(pane).selectFollow()
        #expect(pane.tabs[0].backgroundOverride == nil)
        #expect(backgroundLines(pane.tabs[0]).isEmpty)
    }

    @Test func tabEditAfterPaneEditWins() {
        let pane = pane()
        pane.setBackgroundOverride(Self.paneValue)
        pane.tabs[0].setBackgroundOverride(Self.tabValue)
        #expect(imageLine(pane.tabs[0]) == "background-image = \"\(Self.tabPath)\"")
        #expect(pane.backgroundOverride == Self.paneValue)
    }

    @Test func paneSheetCancelRestoresTabValues() {
        let pane = pane()
        pane.tabs[0].setBackgroundOverride(Self.tabValue)
        let editor = paneEditor(pane)
        editor.selectCustom()
        editor.update { $0.withTerminalOpacity(0.25) }
        #expect(pane.tabs[0].backgroundOverride == nil)
        editor.cancel()
        #expect(pane.backgroundOverride == nil)
        #expect(pane.tabs[0].backgroundOverride == Self.tabValue)
        #expect(pane.tabs[1].backgroundOverride == nil)
        #expect(imageLine(pane.tabs[0]) == "background-image = \"\(Self.tabPath)\"")
    }

    @Test func paneSheetCancelDropsARestoredImageThatWasRemoved() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-tab-cancel-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(String(repeating: "b", count: 64), isDirectory: true)
            .appendingPathComponent("photo.png").path
        let pane = pane()
        pane.tabs[0].setBackgroundOverride(Self.tabValue.withImagePath(path))
        let editor = paneEditor(pane)
        editor.selectCustom()
        editor.cancel()
        #expect(pane.tabs[0].backgroundOverride == Self.tabValue.withImagePath(nil))
    }

    @Test func sessionOverrideDoesNotClearTabValues() {
        let pane = pane()
        let (_, session) = store(pane)
        pane.tabs[0].setBackgroundOverride(Self.tabValue)
        session.setBackgroundOverride(Self.sessionValue)
        #expect(pane.tabs[0].backgroundOverride == Self.tabValue)
        #expect(imageLine(pane.tabs[0]) == "background-image = \"\(Self.tabPath)\"")
        #expect(backgroundLines(pane.tabs[1]).contains("background-opacity = 0.7"))
    }

    // MARK: - Render paths keep it

    @Test func appearanceChangeKeepsTabOverride() {
        let pane = pane()
        let (store, _) = store(pane)
        pane.tabs[0].setBackgroundOverride(Self.tabValue)
        defaults.set(21.0, forKey: SettingsPreference.fontSizeKey)
        store.applyAppearanceToAllSurfaces()
        #expect(imageLine(pane.tabs[0]) == "background-image = \"\(Self.tabPath)\"")
        #expect(pane.tabs[0].terminal.renderedConfig.contains("font-size = 21"))
    }

    @Test func appWideChangeSkipsATabWithItsOwnValue() {
        let pane = pane()
        let (store, _) = store(pane)
        pane.tabs[0].setBackgroundOverride(Self.tabValue)
        configureAppWide()
        store.applyAppearanceToAllSurfaces()
        #expect(imageLine(pane.tabs[0]) == "background-image = \"\(Self.tabPath)\"")
        #expect(imageLine(pane.tabs[1]) == "background-image = \"\(Self.appWidePath)\"")
    }

    @Test func attachContextKeepsTabOverride() {
        let tab = TabRuntime(backgroundGate: gate, backgroundOverride: Self.tabValue)
        #expect(imageLine(tab) == "background-image = \"\(Self.tabPath)\"")
        tab.attachContext(paneID: UUID(), sessionID: UUID())
        #expect(imageLine(tab) == "background-image = \"\(Self.tabPath)\"")
    }

    // MARK: - Scope

    @Test func newTabAndDuplicateDoNotCopyTheTabValue() {
        let pane = pane(tabCount: 1)
        pane.setBackgroundOverride(Self.paneValue)
        pane.tabs[0].setBackgroundOverride(Self.tabValue)
        let duplicate = pane.addTab(inheritingCWDFrom: pane.tabs[0])
        let fresh = pane.addTab()
        #expect(duplicate.backgroundOverride == nil)
        #expect(fresh.backgroundOverride == nil)
        #expect(imageLine(duplicate) == "background-image = \"\(Self.panePath)\"")
    }

    @Test func nonTerminalPaneTabIsNeverGivenOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("batty-tab-bg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ProjectLayout(root: .split(direction: .horizontal, children: [
            .pane(ProjectPane(kind: .gitStatus, tabs: [ProjectTab(background: Self.tabValue)])),
            .pane(.terminal(tabs: [ProjectTab(background: Self.tabValue)])),
        ]))
        let project = Project(name: "T", rootPath: root.path, layout: layout)
        #expect(ProjectDraft(project: project).makeProject().layout.panes[0].tabs.isEmpty)
        let tree = try ProjectTreeBuilder.build(project: project, contentFactory: { _ in nil }, isSessionSelected: true)
        let git = try #require(tree.allPanes.first { $0.kind == .gitStatus })
        #expect(git.tabs.allSatisfy { $0.backgroundOverride == nil })
        let terminal = try #require(tree.allPanes.first { $0.kind == .terminal })
        #expect(terminal.tabs[0].backgroundOverride == Self.tabValue)
    }

    @Test func tabEditorCustomSeedsFromPaneValue() {
        let pane = pane()
        pane.setBackgroundOverride(Self.paneValue)
        let tab = pane.tabs[0]
        BackgroundOverrideEditor(target: tab, appWide: appWide, originalOverride: tab.backgroundOverride).selectCustom()
        #expect(tab.backgroundOverride == Self.paneValue)
        #expect(pane.tabs[1].backgroundOverride == nil)
    }

    @Test func tabScopeFollowTitleNamesTheNextLevel() {
        let pane = pane()
        let (_, session) = store(pane)
        let tab = pane.tabs[0]
        #expect(BackgroundOverrideScope.tab(tab).followTitle == "Follow App Default")
        session.setBackgroundOverride(Self.sessionValue)
        #expect(BackgroundOverrideScope.tab(tab).followTitle == "Follow Session")
        pane.setBackgroundOverride(Self.paneValue)
        #expect(BackgroundOverrideScope.tab(tab).followTitle == "Follow Pane")
        #expect(BackgroundOverrideScope.tab(tab).identifierPrefix == "tab-background-sheet")
        #expect(BackgroundOverrideScope.tab(tab).customTitle == "Custom for This Tab")
    }
}
