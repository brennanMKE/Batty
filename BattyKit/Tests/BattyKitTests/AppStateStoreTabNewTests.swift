// AppStateStoreTabNewTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct AppStateStoreTabNewTests {

    @MainActor
    private final class EventRecorder {
        private(set) var payloads: [WatchEventPayload] = []
        private var subscriptionID: UUID?

        init(events: [String]) {
            subscriptionID = AppEventWatcher.shared.subscribe(events: events) { [weak self] payload in
                MainActor.assumeIsolated {
                    self?.payloads.append(payload)
                }
            }
        }

        func stop() {
            guard let subscriptionID else { return }
            AppEventWatcher.shared.unsubscribe(id: subscriptionID)
            self.subscriptionID = nil
        }
    }

    private func createdTabID(_ outcome: AppStateStore.TabNewOutcome) -> UUID? {
        if case let .created(_, _, tabID) = outcome { return tabID }
        return nil
    }

    @Test func newTabAddsATabToTheTargetPaneAndSelectsIt() throws {
        let store = AppStateStore()
        let session = store.sessions[0]
        let pane = session.focusedPaneAnyKind
        let before = pane.tabs.count

        let outcome = store.newTabForXPC(paneID: pane.id, sourceTabID: nil, command: nil, workingDirectory: nil, background: false)

        let tabID = try #require(createdTabID(outcome))
        #expect(outcome == .created(sessionID: session.id, paneID: pane.id, tabID: tabID))
        #expect(pane.tabs.count == before + 1)
        #expect(pane.activeTabID == tabID)
    }

    @Test func newTabThreadsTheCommandIntoTheTab() throws {
        let store = AppStateStore()
        let pane = store.sessions[0].focusedPaneAnyKind

        let tabID = try #require(createdTabID(store.newTabForXPC(paneID: pane.id, sourceTabID: nil, command: "top", workingDirectory: nil, background: false)))

        let config = try #require(pane.tabs.first { $0.id == tabID }).terminal.renderedConfig
        #expect(config.contains("command = top"))
        #expect(config.contains("wait-after-command = true"))
    }

    @Test func emptyCommandIsTreatedAsNoCommand() throws {
        let store = AppStateStore()
        let pane = store.sessions[0].focusedPaneAnyKind

        let tabID = try #require(createdTabID(store.newTabForXPC(paneID: pane.id, sourceTabID: nil, command: "", workingDirectory: nil, background: false)))

        let config = try #require(pane.tabs.first { $0.id == tabID }).terminal.renderedConfig
        #expect(!config.contains("wait-after-command = true"))
    }

    @Test func newTabUsesTheExplicitWorkingDirectory() throws {
        let store = AppStateStore()
        let pane = store.sessions[0].focusedPaneAnyKind

        let tabID = try #require(createdTabID(store.newTabForXPC(paneID: pane.id, sourceTabID: nil, command: nil, workingDirectory: "/tmp/tab-new-cwd", background: false)))

        let tab = try #require(pane.tabs.first { $0.id == tabID })
        #expect(tab.workingDirectory == "/tmp/tab-new-cwd")
        #expect(tab.terminal.configuration.workingDirectory == "/tmp/tab-new-cwd")
    }

    @Test func tabNewSourcePrefersTheCallersTabInThePane() {
        let store = AppStateStore()
        let pane = store.sessions[0].focusedPaneAnyKind
        let first = pane.tabs[0]
        let second = pane.addTab()
        #expect(pane.activeTabID == second.id)

        #expect(AppStateStore.tabNewSource(in: pane, sourceTabID: first.id) === first)
    }

    @Test func tabNewSourceFallsBackToTheActiveTabForAForeignTab() throws {
        let store = AppStateStore()
        let session = store.sessions[0]
        let pane = session.focusedPaneAnyKind
        let first = pane.tabs[0]
        _ = pane.addTab()
        pane.activeTabID = first.id
        let otherPaneID = try #require(store.splitPane(id: pane.id, direction: .horizontal))
        let foreignTab = try #require(session.tree.allPanes.first { $0.id == otherPaneID }?.tabs.first)

        #expect(AppStateStore.tabNewSource(in: pane, sourceTabID: foreignTab.id) === first)
    }

    @Test func newTabRefusesANonTerminalPane() throws {
        let store = AppStateStore()
        let session = store.sessions[0]
        let split = store.splitPane(id: session.focusedPaneAnyKind.id, direction: .horizontal, kind: .gitStatus, contentFactory: { _ in nil })
        let gitPaneID = try #require(split)
        let gitPane = try #require(session.tree.allPanes.first { $0.id == gitPaneID })
        let before = gitPane.tabs.count

        #expect(store.newTabForXPC(paneID: gitPaneID, sourceTabID: nil, command: nil, workingDirectory: nil, background: false) == .notTerminal)
        #expect(gitPane.tabs.count == before)
    }

    @Test func newTabReturnsUnknownPaneForAnUnknownID() {
        let store = AppStateStore()
        #expect(store.newTabForXPC(paneID: UUID(), sourceTabID: nil, command: nil, workingDirectory: nil, background: false) == .unknownPane)
    }

    @Test func backgroundLeavesTheActiveTabUnchanged() throws {
        let store = AppStateStore()
        let pane = store.sessions[0].focusedPaneAnyKind
        let original = pane.activeTabID

        let tabID = try #require(createdTabID(store.newTabForXPC(paneID: pane.id, sourceTabID: nil, command: nil, workingDirectory: nil, background: true)))

        #expect(pane.activeTabID == original)
        #expect(pane.tabs.last?.id == tabID)
    }

    @Test func newTabKeepsTheFocusedPane() throws {
        let store = AppStateStore()
        let session = store.sessions[0]
        let paneA = session.focusedPaneAnyKind.id
        let paneB = try #require(store.splitPane(id: paneA, direction: .horizontal))
        store.windows[0].focusPane(id: paneA)
        #expect(session.tree.focusedPaneID == paneA)
        let selectedBefore = store.windows[0].selectedSessionID

        _ = try #require(createdTabID(store.newTabForXPC(paneID: paneB, sourceTabID: nil, command: nil, workingDirectory: nil, background: false)))

        #expect(session.tree.focusedPaneID == paneA)
        #expect(store.windows[0].selectedSessionID == selectedBefore)
    }

    @Test func newTabInABackgroundSessionDoesNotSwitchTheSelectedSession() throws {
        let store = AppStateStore()
        let first = store.sessions[0]
        let second = try #require(store.addSession(title: "background"))
        store.windows[0].selectedSessionID = first.id

        let outcome = store.newTabForXPC(paneID: second.focusedPaneAnyKind.id, sourceTabID: nil, command: nil, workingDirectory: nil, background: false)

        #expect(createdTabID(outcome) != nil)
        #expect(store.windows[0].selectedSessionID == first.id)
    }

    @Test func newTabEmitsTabCreatedFromCli() throws {
        let store = AppStateStore()
        let pane = store.sessions[0].focusedPaneAnyKind
        let recorder = EventRecorder(events: ["tab_created"])
        defer { recorder.stop() }

        let tabID = try #require(createdTabID(store.newTabForXPC(paneID: pane.id, sourceTabID: nil, command: nil, workingDirectory: nil, background: false)))

        let mine = recorder.payloads.filter { $0.tabID == tabID }
        #expect(mine.count == 1)
        #expect(mine.first?.targetPaneID == pane.id)
        #expect(mine.first?.fromCli == true)
    }
}
