// TerminalHostStoreReleaseObserverTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct TerminalHostStoreReleaseObserverTests {
    @Test func releaseNotifiesThatTabsObservers() {
        let store = TerminalHostStore()
        let tabID = UUID()
        var calls = 0
        store.addReleaseObserver(forTabID: tabID) { calls += 1 }
        store.releaseTerminalView(forTabID: tabID)
        #expect(calls == 1)
    }

    @Test func releaseOfAnotherTabDoesNotNotify() {
        let store = TerminalHostStore()
        var calls = 0
        store.addReleaseObserver(forTabID: UUID()) { calls += 1 }
        store.releaseTerminalView(forTabID: UUID())
        #expect(calls == 0)
    }

    @Test func removedObserverIsNotCalled() {
        let store = TerminalHostStore()
        let tabID = UUID()
        var calls = 0
        let token = store.addReleaseObserver(forTabID: tabID) { calls += 1 }
        store.removeReleaseObserver(token)
        store.releaseTerminalView(forTabID: tabID)
        #expect(calls == 0)
    }
}
