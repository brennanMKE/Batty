// SessionSelectedFlagTests.swift

import Foundation
import Observation
import Testing
@testable import BattyKit

/// `onChange` runs synchronously in the write, on the writer's thread (the
/// main actor here); the box only has to cross the `@Sendable` signature.
private nonisolated final class FiredIndices: @unchecked Sendable {
    var indices: [Int] = []
}

/// Pins `SessionRuntime.isSelected` (#0604): the per-Session selected fact the
/// Sidebar rows read. It follows `WindowRuntime.selectedSessionID` on every
/// selection path and is written only on the (at most) two Sessions a change
/// crosses, so a switch invalidates two rows, not every row.
@MainActor
struct SessionSelectedFlagTests {
    private func makeWindow(sessionCount: Int) -> WindowRuntime {
        let window = WindowRuntime(bellFeed: BellFeedStore(), nameCache: SessionNameCache())
        while window.sessions.count < sessionCount {
            window.addSession()
        }
        window.selectSession(at: 0)
        return window
    }

    private func releaseTerminals(in window: WindowRuntime) {
        for session in window.sessions {
            for pane in session.tree.allPanes {
                for tab in pane.tabs {
                    TerminalHostStore.shared.releaseTerminalView(forTabID: tab.id)
                }
            }
        }
    }

    private func selectedIndices(in window: WindowRuntime) -> [Int] {
        window.sessions.indices.filter { window.sessions[$0].isSelected }
    }

    /// Registers a one-shot observation on every Session's `isSelected` and
    /// returns the indices whose observation fired. `onChange` runs
    /// synchronously in the write, so reading the box after the action needs
    /// no waiting.
    private func observeIsSelected(in window: WindowRuntime, during action: () -> Void) -> [Int] {
        let box = FiredIndices()
        for (index, session) in window.sessions.enumerated() {
            withObservationTracking {
                _ = session.isSelected
            } onChange: {
                box.indices.append(index)
            }
        }
        action()
        return box.indices.sorted()
    }

    @Test func initialSessionIsSelected() {
        let store = AppStateStore()
        let window = store.windows[0]
        defer { releaseTerminals(in: window) }
        #expect(window.sessions.count == 1)
        #expect(window.sessions[0].isSelected)
    }

    @Test func switchFlipsOnlyTheTwoSessionsInvolved() {
        let window = makeWindow(sessionCount: 16)
        defer { releaseTerminals(in: window) }
        #expect(selectedIndices(in: window) == [0])

        let fired = observeIsSelected(in: window) { window.selectSession(at: 5) }

        #expect(fired == [0, 5])
        #expect(selectedIndices(in: window) == [5])
    }

    @Test func reselectingTheSelectedSessionWritesNothing() {
        let window = makeWindow(sessionCount: 4)
        defer { releaseTerminals(in: window) }
        window.selectSession(at: 2)

        let fired = observeIsSelected(in: window) { window.selectSession(at: 2) }

        #expect(fired.isEmpty)
        #expect(selectedIndices(in: window) == [2])
    }

    @Test func removingTheSelectedSessionSelectsTheNext() {
        let window = makeWindow(sessionCount: 4)
        defer { releaseTerminals(in: window) }
        window.selectSession(at: 2)
        let removedID = window.sessions[2].id

        window.removeSession(id: removedID)

        #expect(window.sessions.count == 3)
        let selected = window.sessions.filter(\.isSelected)
        #expect(selected.count == 1)
        #expect(selected.first?.id == window.selectedSessionID)
        #expect(window.selectedSessionID != removedID)
    }

    @Test func duplicateAndAddSelectTheNewSession() throws {
        let window = makeWindow(sessionCount: 3)
        defer { releaseTerminals(in: window) }

        let copy = try #require(window.duplicateSession(id: window.sessions[0].id))
        #expect(window.sessions.filter(\.isSelected).map(\.id) == [copy.id])

        let added = window.addSession()
        #expect(window.sessions.filter(\.isSelected).map(\.id) == [added.id])
    }

    @Test func rejectedSidebarWriteLeavesFlagsUnchanged() {
        let window = makeWindow(sessionCount: 4)
        defer { releaseTerminals(in: window) }
        window.selectSession(at: 1)
        let paneID = window.sessions[2].tree.allPanes[0].id

        let fired = observeIsSelected(in: window) {
            window.selectSessionFromSidebar(id: paneID)
            window.selectSessionFromSidebar(id: nil)
        }

        #expect(fired.isEmpty)
        #expect(selectedIndices(in: window) == [1])
    }
}
