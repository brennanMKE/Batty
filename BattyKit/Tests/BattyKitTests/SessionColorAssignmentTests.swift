// SessionColorAssignmentTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct SessionColorAssignmentTests {

    private func makeWindow() -> WindowRuntime {
        WindowRuntime(bellFeed: BellFeedStore(), nameCache: SessionNameCache())
    }

    // MARK: - Assignment order and wrap-around

    @Test func tenConsecutiveSessionsGetTenDistinctColors() {
        let window = makeWindow()
        // The window already starts with one Session (index 0, Blue).
        var indices = [window.sessions[0].colorIndex]
        for _ in 1..<10 {
            indices.append(window.addSession().colorIndex)
        }
        #expect(Set(indices).count == 10)
        #expect(Set(indices) == Set(0..<10))
    }

    @Test func eleventhSessionWrapsAndReusesAnIndex() {
        let window = makeWindow()
        for _ in 1..<10 {
            window.addSession()
        }
        #expect(window.sessions.count == 10)
        let eleventh = window.addSession()
        #expect(Set(0..<10).contains(eleventh.colorIndex))
        // With 10 live sessions holding every index once, the 11th must
        // reuse one — every index is tied at usage 1, so the wrap picks
        // the one right after the most recently assigned index (0, the
        // one the very first session got, since assignment walked 0...9).
        #expect(eleventh.colorIndex == 0)
    }

    @Test func assignmentSpreadsAcrossPaletteBeforeAnyIndexRepeats() {
        let window = makeWindow()
        for _ in 1..<10 {
            window.addSession()
        }
        // Every one of the 10 palette indices should be in use exactly
        // once before the 11th session forces a repeat.
        let indices = window.sessions.map(\.colorIndex).sorted()
        #expect(indices == Array(0..<10))
    }

    // MARK: - Stability

    @Test func colorIndexDoesNotChangeWhenOtherSessionsAreAddedOrClosed() {
        let window = makeWindow()
        let first = window.sessions[0]
        let firstColor = first.colorIndex

        let second = window.addSession()
        let secondColor = second.colorIndex
        window.addSession()
        window.addSession()

        #expect(first.colorIndex == firstColor)
        #expect(second.colorIndex == secondColor)

        window.removeSession(id: second.id)
        #expect(first.colorIndex == firstColor)
    }

    @Test func colorIndexDoesNotChangeOnReorderOrRename() {
        let window = makeWindow()
        let first = window.sessions[0]
        let firstColor = first.colorIndex
        window.addSession()
        window.addSession()

        window.moveSessions(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        window.renameSession(id: first.id, to: "Renamed")

        #expect(first.colorIndex == firstColor)
    }

    @Test func closingASessionFreesItsIndexForTheNextLeastUsedPick() {
        let window = makeWindow()
        for _ in 1..<10 {
            window.addSession()
        }
        // Every index 0...9 in use once. Close the session holding index 1.
        guard let holderOfOne = window.sessions.first(where: { $0.colorIndex == 1 }) else {
            Issue.record("Expected a session holding color index 1")
            return
        }
        window.removeSession(id: holderOfOne.id)

        // The next new session should prefer the now-unused index 1 over
        // any still-in-use index, since it is the least-used (0 vs 1).
        let next = window.addSession()
        #expect(next.colorIndex == 1)
    }

    // MARK: - Duplicate gets a fresh color

    @Test func duplicateSessionGetsAFreshColorNotTheSources() {
        let window = makeWindow()
        let source = window.sessions[0]
        let duplicate = window.duplicateSession(id: source.id)
        #expect(duplicate != nil)
        #expect(duplicate?.colorIndex != source.colorIndex)
    }

    // MARK: - Per-window scoping

    @Test func assignmentIsScopedPerWindowNotGlobal() {
        let windowA = makeWindow()
        let windowB = makeWindow()
        // Both windows independently start their first session at index 0.
        #expect(windowA.sessions[0].colorIndex == 0)
        #expect(windowB.sessions[0].colorIndex == 0)
    }

    // MARK: - SessionColor enum surface

    @Test func sessionColorHasExactlyTenCases() {
        #expect(SessionColor.allCases.count == 10)
    }

    @Test func sessionRuntimeResolvesSessionColorFromIndex() {
        let session = SessionRuntime(colorIndex: 4)
        #expect(session.sessionColor == .teal)
    }
}
