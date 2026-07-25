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
}
