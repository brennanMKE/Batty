// RemoveSessionSelectionTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct RemoveSessionSelectionTests {

    @Test func closingRightmostSelectsPriorNeighbor() {
        let store = AppStateStore()
        let s1 = store.sessions[0]
        let s2 = store.addSession()!
        let s3 = store.addSession()!
        store.selectedSessionID = s3.id

        store.removeSession(id: s3.id)

        #expect(store.selectedSessionID == s2.id)
        _ = s1
    }

    @Test func closingMiddleSelectsLeftNeighbor() {
        let store = AppStateStore()
        let s1 = store.sessions[0]
        let s2 = store.addSession()!
        let s3 = store.addSession()!
        store.selectedSessionID = s2.id

        store.removeSession(id: s2.id)

        #expect(store.selectedSessionID == s1.id)
        _ = s3
    }

    @Test func closingLeftmostSelectsNewLeftmost() {
        let store = AppStateStore()
        let s1 = store.sessions[0]
        let s2 = store.addSession()!

        store.removeSession(id: s1.id)

        #expect(store.selectedSessionID == s2.id)
    }
}
