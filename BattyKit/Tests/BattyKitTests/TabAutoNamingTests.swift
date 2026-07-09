// TabAutoNamingTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Test double for the per-tab AI naming step: returns a canned result and
/// records every path it was asked about. Mirrors `RecordingSuggester` in
/// `AISessionNamingTests.swift` but kept file-local per this codebase's
/// existing convention for test doubles.
private final class RecordingTabSuggester: SessionNameSuggesting {
    var result: String?
    private(set) var requestedPaths: [String] = []

    init(result: String?) {
        self.result = result
    }

    func suggestName(forPath path: String) async -> String? {
        requestedPaths.append(path)
        return result
    }
}

@MainActor
struct TabAutoNamingTests {

    private func makeStore(suggester: SessionNameSuggesting?) -> (AppStateStore, URL) {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-tab-ai-naming-\(UUID().uuidString)")
            .appendingPathComponent("session-name-cache.json")
        let cache = SessionNameCache(fileURL: cacheURL, debounce: .zero)
        let store = AppStateStore(nameCache: cache)
        store.nameSuggester = suggester
        return (store, cacheURL)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func awaitSuggestion(_ store: AppStateStore, tabID: UUID) async {
        if let inflight = store.tabNameSuggestionTasks[tabID] {
            await inflight.task.value
        }
    }

    private func withPreferences(_ values: [String: Bool], _ body: () -> Void) {
        let defaults = UserDefaults.standard
        for (key, value) in values { defaults.set(value, forKey: key) }
        defer { for key in values.keys { defaults.removeObject(forKey: key) } }
        body()
    }

    // MARK: - Gating: AI setting

    @Test func aiNameAppliesWhenSettingOnAndSuggesterReturnsAName() async {
        let suggester = RecordingTabSuggester(result: "Meeting Notes")
        let (store, url) = makeStore(suggester: suggester)
        defer { cleanup(url) }

        let tab = TabRuntime()
        tab.terminal.configuration.workingDirectory = "/Users/test/meeting notes 2026"
        withPreferences([SettingsPreference.autoNameWithAIKey: true]) {
            store.updateTabAutoName(for: tab)
        }
        await awaitSuggestion(store, tabID: tab.id)

        #expect(tab.aiSuggestedName == "Meeting Notes")
        #expect(suggester.requestedPaths == ["/Users/test/meeting notes 2026"])
    }

    @Test func aiNameNeverScheduledWhenSettingOff() {
        let suggester = RecordingTabSuggester(result: "AI Name")
        let (store, url) = makeStore(suggester: suggester)
        defer { cleanup(url) }

        let tab = TabRuntime()
        tab.terminal.configuration.workingDirectory = "/Users/test/no-project-here"
        withPreferences([SettingsPreference.autoNameWithAIKey: false]) {
            store.updateTabAutoName(for: tab)
        }

        #expect(tab.aiSuggestedName == nil)
        #expect(store.tabNameSuggestionTasks[tab.id] == nil)
        #expect(suggester.requestedPaths.isEmpty)
    }

    @Test func nilSuggesterLeavesNameNil() {
        let (store, url) = makeStore(suggester: nil)
        defer { cleanup(url) }

        let tab = TabRuntime()
        tab.terminal.configuration.workingDirectory = "/Users/test/no-suggester"
        withPreferences([SettingsPreference.autoNameWithAIKey: true]) {
            store.updateTabAutoName(for: tab)
        }

        #expect(tab.aiSuggestedName == nil)
        #expect(store.tabNameSuggestionTasks[tab.id] == nil)
    }

    // MARK: - User override suppresses auto-naming

    @Test func titleOverrideSuppressesAutoNaming() async {
        let suggester = RecordingTabSuggester(result: "Cool Name")
        let (store, url) = makeStore(suggester: suggester)
        defer { cleanup(url) }

        let tab = TabRuntime(titleOverride: "My Tab")
        tab.terminal.configuration.workingDirectory = "/Users/test/some-project"
        withPreferences([SettingsPreference.autoNameWithAIKey: true]) {
            store.updateTabAutoName(for: tab)
        }

        #expect(tab.aiSuggestedName == nil)
        #expect(store.tabNameSuggestionTasks[tab.id] == nil)
        #expect(suggester.requestedPaths.isEmpty)
    }

    @Test func lateResultDroppedAfterOverrideLandsMidFlight() async {
        let suggester = RecordingTabSuggester(result: "Cool Name")
        let (store, url) = makeStore(suggester: suggester)
        defer { cleanup(url) }

        let tab = TabRuntime()
        tab.terminal.configuration.workingDirectory = "/Users/test/folder-a"
        withPreferences([SettingsPreference.autoNameWithAIKey: true]) {
            store.updateTabAutoName(for: tab)
        }
        let inflight = store.tabNameSuggestionTasks[tab.id]
        #expect(inflight != nil)

        // The user renames the tab before the model answers.
        tab.titleOverride = "Renamed"
        await inflight?.task.value

        #expect(tab.aiSuggestedName == nil)
    }

    @Test func resetAfterOverrideResumesAutoNamingWhenRequested() async {
        let suggester = RecordingTabSuggester(result: "Cool Name")
        let (store, url) = makeStore(suggester: suggester)
        defer { cleanup(url) }

        let tab = TabRuntime(titleOverride: "My Tab")
        tab.terminal.configuration.workingDirectory = "/Users/test/folder-a"
        withPreferences([SettingsPreference.autoNameWithAIKey: true]) {
            store.updateTabAutoName(for: tab)
        }
        #expect(tab.aiSuggestedName == nil)
        #expect(suggester.requestedPaths.isEmpty)

        // Reset Title / an empty rename-sheet commit clears the override —
        // callers immediately re-invoke updateTabAutoName (PaneView does this
        // from both the context-menu Reset Title action and an empty commit).
        tab.titleOverride = nil
        withPreferences([SettingsPreference.autoNameWithAIKey: true]) {
            store.updateTabAutoName(for: tab)
        }
        await awaitSuggestion(store, tabID: tab.id)

        #expect(tab.aiSuggestedName == "Cool Name")
    }

    // MARK: - Staleness

    @Test func staleCwdResultIsDropped() async {
        let suggester = RecordingTabSuggester(result: "Cool Name")
        let (store, url) = makeStore(suggester: suggester)
        defer { cleanup(url) }

        let tab = TabRuntime()
        tab.terminal.configuration.workingDirectory = "/Users/test/folder-a"
        withPreferences([SettingsPreference.autoNameWithAIKey: true]) {
            store.updateTabAutoName(for: tab)
        }
        let inflight = store.tabNameSuggestionTasks[tab.id]
        #expect(inflight != nil)

        // The shell moves on before the model answers.
        tab.terminal.configuration.workingDirectory = "/Users/test/folder-b"
        await inflight?.task.value

        #expect(tab.aiSuggestedName == nil)
    }

    // MARK: - Memo sharing with session naming (keyed purely by cwd)

    @Test func tabNamingReusesSessionMemoWithoutReprompting() async {
        let suggester = RecordingTabSuggester(result: "Cool Name")
        let (store, url) = makeStore(suggester: suggester)
        defer { cleanup(url) }

        // Prime the shared memo via the session-naming path.
        let session = store.sessions[0]
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/shared-folder"
        withPreferences([SettingsPreference.autoNameWithAIKey: true]) {
            store.handleWorkingDirectoryChange(forTabID: anchorTab.id)
        }
        if let inflight = store.nameSuggestionTasks[session.id] {
            await inflight.task.value
        }
        #expect(suggester.requestedPaths == ["/Users/test/shared-folder"])

        // A second, unrelated tab visiting the same cwd should hit the memo,
        // not the model again.
        let otherTab = TabRuntime()
        otherTab.terminal.configuration.workingDirectory = "/Users/test/shared-folder"
        withPreferences([SettingsPreference.autoNameWithAIKey: true]) {
            store.updateTabAutoName(for: otherTab)
        }

        #expect(otherTab.aiSuggestedName == "Cool Name")
        #expect(suggester.requestedPaths.count == 1)
        #expect(store.tabNameSuggestionTasks[otherTab.id] == nil)
    }

    @Test func repeatCallForSameCwdDoesNotRestartRequest() async {
        let suggester = RecordingTabSuggester(result: "Cool Name")
        let (store, url) = makeStore(suggester: suggester)
        defer { cleanup(url) }

        let tab = TabRuntime()
        tab.terminal.configuration.workingDirectory = "/Users/test/folder-a"
        withPreferences([SettingsPreference.autoNameWithAIKey: true]) {
            store.updateTabAutoName(for: tab)
            store.updateTabAutoName(for: tab)
        }
        await awaitSuggestion(store, tabID: tab.id)

        #expect(tab.aiSuggestedName == "Cool Name")
        #expect(suggester.requestedPaths.count == 1)
    }

    // MARK: - NONE / junk outcomes

    @Test func noneResultLeavesNameNilAndIsMemoized() async {
        let suggester = RecordingTabSuggester(result: nil)
        let (store, url) = makeStore(suggester: suggester)
        defer { cleanup(url) }

        let tab = TabRuntime()
        tab.terminal.configuration.workingDirectory = "/Users/test/untitled folder 3"
        withPreferences([SettingsPreference.autoNameWithAIKey: true]) {
            store.updateTabAutoName(for: tab)
        }
        await awaitSuggestion(store, tabID: tab.id)

        #expect(tab.aiSuggestedName == nil)

        withPreferences([SettingsPreference.autoNameWithAIKey: true]) {
            store.updateTabAutoName(for: tab)
        }
        await awaitSuggestion(store, tabID: tab.id)

        #expect(suggester.requestedPaths.count == 1)
    }

    // MARK: - Observation bridge (TabRuntime.syncWorkingDirectoryFromTerminal)

    @Test func syncMirrorsLiveWorkingDirectoryIntoObservedProperty() {
        let tab = TabRuntime()
        #expect(tab.workingDirectory == nil)

        tab.terminalDelegate.terminalDidChangeWorkingDirectory("/Users/test/project")
        // The live Combine value moved, but the Observation-tracked mirror
        // only updates once synced — exactly the gap that left chips stale.
        #expect(tab.workingDirectory == nil)

        let changed = tab.syncWorkingDirectoryFromTerminal()
        #expect(changed == true)
        #expect(tab.workingDirectory == "/Users/test/project")

        let changedAgain = tab.syncWorkingDirectoryFromTerminal()
        #expect(changedAgain == false)
        #expect(tab.workingDirectory == "/Users/test/project")
    }

    @Test func chipTitleReadsMirrorNotLiveTerminalValue() {
        let tab = TabRuntime()
        tab.terminal.configuration.workingDirectory = "/Users/test/Developer/SomeProject"
        // Mirror hasn't been synced yet — chip falls back.
        #expect(TabTitleFormatter.chipTitle(for: tab) == "Tab")

        tab.workingDirectory = "/Users/test/Developer/SomeProject"
        #expect(TabTitleFormatter.chipTitle(for: tab) == "SomeProject")
    }

    // MARK: - Sidebar pane row "first tab" selection (#0260)

    @Test func paneRowLabelReturnsPositionOnlyWhenPaneHasNoTabs() {
        let label = PaneRow.label(position: "1/1", firstTab: nil)
        #expect(label == "1/1")
    }

    @Test func paneRowLabelUsesFirstTabRegardlessOfActiveTab() {
        let pane = PaneRuntime(tabs: [
            TabRuntime(titleOverride: "Frontend"),
            TabRuntime(titleOverride: "Backend"),
        ])
        pane.activeTabID = pane.tabs[1].id // "Backend" is active…

        let label = PaneRow.label(position: "1/1", firstTab: pane.tabs.first)

        // …but the row must describe the pane via its FIRST tab, not the
        // active one.
        #expect(label == "1/1 — Frontend")
    }

    @Test func paneRowLabelFollowsFirstTabAfterReorder() {
        let pane = PaneRuntime(tabs: [
            TabRuntime(titleOverride: "Frontend"),
            TabRuntime(titleOverride: "Backend"),
        ])
        // Simulate a drag-reorder: Backend moves to index 0.
        pane.tabs.swapAt(0, 1)

        let label = PaneRow.label(position: "1/1", firstTab: pane.tabs.first)

        #expect(label == "1/1 — Backend")
    }

    @Test func paneRowLabelMatchesFirstTabChipTitleExactly() {
        let suggester = RecordingTabSuggester(result: "Cool Name")
        _ = suggester // documents parity with chipTitle; no AI call needed here
        let firstTab = TabRuntime()
        firstTab.runningCommandDisplayName = "Claude Code"

        let label = PaneRow.label(position: "2/1", firstTab: firstTab)

        #expect(label == "2/1 — \(TabTitleFormatter.chipTitle(for: firstTab))")
        #expect(label == "2/1 — Claude Code")
    }
}
