// AppStateStoreStatusPayloadTests.swift

import BattyXPCCore
import Foundation
import Testing
@testable import BattyKit

/// Covers `AppStateStore.statusPayload()`, the app-side source of the
/// `status` XPC verb's response (#0271).
@MainActor
struct AppStateStoreStatusPayloadTests {

    @Test func statusPayloadReportsCurrentProcessID() {
        let store = AppStateStore()
        let payload = store.statusPayload()
        #expect(payload.pid == ProcessInfo.processInfo.processIdentifier)
    }

    @Test func statusPayloadUptimeIsNonNegativeAndSmallJustAfterInit() {
        let store = AppStateStore()
        let payload = store.statusPayload()
        #expect(payload.uptimeSeconds >= 0)
        #expect(payload.uptimeSeconds < 5)
    }

    @Test func statusPayloadReportsWindowCount() {
        let store = AppStateStore()
        #expect(store.statusPayload().windowCount == store.windows.count)
    }

    @Test func statusPayloadReportsSessionCountAcrossAllWindows() {
        let store = AppStateStore()
        _ = store.addSession()
        _ = store.addSession()
        let expected = store.windows.reduce(0) { $0 + $1.sessions.count }
        #expect(store.statusPayload().sessionCount == expected)
        #expect(expected >= 2)
    }

    @Test func statusPayloadTabCountMatchesAllPanesTabsAcrossWindows() {
        let store = AppStateStore()
        _ = store.addSession()
        let expected = store.windows.reduce(0) { acc, window in
            acc + window.sessions.flatMap { $0.tree.allPanes }.flatMap { $0.tabs }.count
        }
        #expect(store.statusPayload().tabCount == expected)
        #expect(expected > 0)
    }

    /// #0315 review round 1, finding 3: a non-terminal pane's one
    /// `TabRuntime` is a structural placeholder `PaneView` never renders —
    /// `batty status`'s `tabCount` must not count it.
    @Test func statusPayloadTabCountExcludesNonTerminalPanes() {
        let store = AppStateStore()
        let session = store.sessions.first!
        let terminalPane = session.focusedPane
        let before = store.statusPayload().tabCount

        _ = session.tree.splitPane(id: terminalPane.id, direction: .horizontal, kind: .processStatus)

        #expect(store.statusPayload().tabCount == before)
    }
}
