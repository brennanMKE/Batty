// SessionColorOverrideTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct SessionColorOverrideTests {

    private func makeWindow() -> WindowRuntime {
        WindowRuntime(bellFeed: BellFeedStore(), nameCache: SessionNameCache())
    }

    // MARK: - Setting and stickiness

    @Test func setSessionColorMarksTheSessionAsExplicitlyColored() {
        let window = makeWindow()
        let session = window.sessions[0]
        window.setSessionColor(id: session.id, to: 7)
        #expect(session.colorIndex == 7)
        #expect(session.colorOverride)
    }

    @Test func explicitColorSurvivesSubsequentAutomaticAssignments() {
        let window = makeWindow()
        let session = window.sessions[0]
        window.setSessionColor(id: session.id, to: 3)

        for _ in 0..<5 {
            window.addSession()
        }
        window.duplicateSession(id: window.sessions.last!.id)

        #expect(session.colorIndex == 3)
        #expect(session.colorOverride)
    }

    @Test func setSessionColorRejectsAnOutOfRangeIndex() {
        let window = makeWindow()
        let session = window.sessions[0]
        let originalIndex = session.colorIndex
        window.setSessionColor(id: session.id, to: 999)
        #expect(session.colorIndex == originalIndex)
        #expect(!session.colorOverride)
    }

    @Test func setSessionColorIsANoOpForAnUnknownSessionID() {
        let window = makeWindow()
        // No crash, no side effects on the real session.
        window.setSessionColor(id: UUID(), to: 2)
        #expect(window.sessions[0].colorOverride == false)
    }

    // MARK: - Duplicates allowed

    @Test func twoSessionsCanShareTheSameExplicitColor() {
        let window = makeWindow()
        let second = window.addSession()
        window.setSessionColor(id: window.sessions[0].id, to: 5)
        window.setSessionColor(id: second.id, to: 5)
        #expect(window.sessions[0].colorIndex == 5)
        #expect(second.colorIndex == 5)
    }

    // MARK: - Assigner interaction: explicit colors count toward the tally

    @Test func explicitColorsCountTowardTheAssignersInUseTally() {
        let window = makeWindow()
        // Pin the bootstrap session (index 0) to index 5, the same index a
        // fresh least-used pick would otherwise prefer once 0 is vacated
        // below — explicit colors must still show up in the tally.
        window.setSessionColor(id: window.sessions[0].id, to: 5)

        for _ in 1..<10 {
            window.addSession()
        }
        // Every index 0...9 should be in use exactly once, including index
        // 5 via the explicit pin rather than an automatic assignment. If
        // the pin weren't counted, index 5 would still show usage 0 here
        // and a later index would end up doubled instead.
        let indices = window.sessions.map(\.colorIndex).sorted()
        #expect(indices == Array(0..<10))
    }

    // MARK: - Reset

    @Test func resetSessionColorClearsTheOverrideWithoutChangingTheIndex() {
        let window = makeWindow()
        let session = window.sessions[0]
        window.setSessionColor(id: session.id, to: 8)
        #expect(session.colorOverride)

        window.resetSessionColor(id: session.id)
        #expect(!session.colorOverride)
        // Stays at the color it showed — no immediate re-derivation.
        #expect(session.colorIndex == 8)
    }

    @Test func resetSessionColorIsANoOpWhenNoOverrideIsSet() {
        let window = makeWindow()
        let session = window.sessions[0]
        let originalIndex = session.colorIndex
        window.resetSessionColor(id: session.id)
        #expect(!session.colorOverride)
        #expect(session.colorIndex == originalIndex)
    }

    @Test func settingResettingAndSettingAgainRoundTripsCleanly() {
        let window = makeWindow()
        let session = window.sessions[0]

        window.setSessionColor(id: session.id, to: 9)
        #expect(session.colorOverride)

        window.resetSessionColor(id: session.id)
        #expect(!session.colorOverride)
        #expect(session.colorIndex == 9)

        window.setSessionColor(id: session.id, to: 2)
        #expect(session.colorOverride)
        #expect(session.colorIndex == 2)
    }

    // MARK: - Acceptance criteria: survives closing other Sessions and reorder

    @Test func explicitColorSurvivesClosingOtherSessions() {
        let window = makeWindow()
        let pinned = window.sessions[0]
        window.setSessionColor(id: pinned.id, to: 6)

        let second = window.addSession()
        let third = window.addSession()
        window.removeSession(id: second.id)
        window.removeSession(id: third.id)

        #expect(pinned.colorIndex == 6)
        #expect(pinned.colorOverride)
    }

    @Test func explicitColorSurvivesReorder() {
        let window = makeWindow()
        let pinned = window.sessions[0]
        window.setSessionColor(id: pinned.id, to: 6)
        window.addSession()
        window.addSession()

        window.moveSessions(fromOffsets: IndexSet(integer: 0), toOffset: 2)

        #expect(pinned.colorIndex == 6)
        #expect(pinned.colorOverride)
    }
}
