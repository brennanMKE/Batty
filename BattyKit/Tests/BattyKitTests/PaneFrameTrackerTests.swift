// PaneFrameTrackerTests.swift

import AppKit
import SwiftUI
import Testing
@testable import BattyKit

@MainActor
struct PaneFrameTrackerTests {

    @Test func recordThenRemoveBySameOwnerDropsTheEntry() {
        let tracker = PaneFrameTracker()
        let paneID = UUID()
        let owner = UUID()
        tracker.record(CGRect(x: 10, y: 20, width: 300, height: 200), for: paneID, owner: owner)
        #expect(tracker.frames[paneID] == CGRect(x: 10, y: 20, width: 300, height: 200))
        tracker.remove(paneID: paneID, owner: owner)
        #expect(tracker.frames[paneID] == nil)
    }

    @Test func removeByStaleOwnerKeepsTheSuccessorsEntry() {
        let tracker = PaneFrameTracker()
        let paneID = UUID()
        let stale = UUID()
        let successor = UUID()
        tracker.record(CGRect(x: 0, y: 0, width: 1200, height: 800), for: paneID, owner: stale)
        tracker.record(CGRect(x: 0, y: 0, width: 600, height: 800), for: paneID, owner: successor)
        tracker.remove(paneID: paneID, owner: stale)
        #expect(tracker.frames[paneID] == CGRect(x: 0, y: 0, width: 600, height: 800))
    }

    // MARK: - Hosted

    private struct HostedSession: View {
        let session: SessionRuntime
        let windowID: WindowID

        var body: some View {
            SplitContainerView(tree: session.tree)
                .coordinateSpace(name: "session")
                .environment(\.paneFrameTracker, session.paneFrames)
                .environment(\.windowID, windowID)
                .frame(width: 1200, height: 800)
        }
    }

    private final class Hosted {
        let window: NSWindow
        let view: NSView
        let session: SessionRuntime
        let windowID: WindowID

        init(session: SessionRuntime) {
            self.session = session
            windowID = WindowID()
            let size = CGSize(width: 1200, height: 800)
            let hostingView = NSHostingView(rootView: HostedSession(session: session, windowID: windowID))
            hostingView.frame = CGRect(origin: .zero, size: size)
            window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
            window.contentView = hostingView
            view = hostingView
        }

        func tearDown() {
            for pane in session.tree.allPanes {
                for tab in pane.tabs {
                    TerminalHostStore.shared.releaseTerminalView(forTabID: tab.id)
                }
            }
            TerminalHostStore.shared.releaseHost(forWindowID: windowID)
        }
    }

    /// The same turn-bounded main-queue hop as `PaneViewRenderTests.pump`:
    /// the condition is rechecked after every real turn, and `maxTurns` is a
    /// hang-guard only.
    private func pump(
        _ view: NSView,
        until condition: () -> Bool,
        maxTurns: Int = 200,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        view.layoutSubtreeIfNeeded()
        for _ in 0..<maxTurns {
            if condition() { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            view.layoutSubtreeIfNeeded()
        }
        if !condition() {
            Issue.record("Timed out after \(maxTurns) main-queue turns waiting for Pane frames", sourceLocation: sourceLocation)
        }
    }

    private func split(_ store: AppStateStore, _ id: UUID, _ direction: SplitDirection) throws -> UUID {
        let newID = store.splitPane(id: id, direction: direction, kind: .gitStatus, contentFactory: { _ in nil })
        return try #require(newID)
    }

    @Test func focusPaneAdjacentUsesRecordedFrames() async throws {
        let store = AppStateStore()
        let session = store.sessions[0]
        let topLeft = session.focusedPaneAnyKind.id
        let topRight = try split(store, topLeft, .horizontal)
        let bottomLeft = try split(store, topLeft, .vertical)
        let bottomRight = try split(store, topRight, .vertical)
        let hosted = Hosted(session: session)
        defer { hosted.tearDown() }

        let ids = [topLeft, topRight, bottomLeft, bottomRight]
        await pump(hosted.view, until: { ids.allSatisfy { session.paneFrames.frames[$0] != nil } })
        let recorded = ids.allSatisfy { session.paneFrames.frames[$0] != nil }
        try #require(recorded)

        session.tree.focusedPaneID = topLeft
        session.focusPane(adjacent: .right)
        #expect(session.tree.focusedPaneID == topRight)
        session.focusPane(adjacent: .down)
        #expect(session.tree.focusedPaneID == bottomRight)
        session.focusPane(adjacent: .left)
        #expect(session.tree.focusedPaneID == bottomLeft)
        session.focusPane(adjacent: .up)
        #expect(session.tree.focusedPaneID == topLeft)
    }

    @Test func closedPaneFrameIsDropped() async throws {
        let store = AppStateStore()
        let session = store.sessions[0]
        let survivor = session.focusedPaneAnyKind.id
        let closed = try split(store, survivor, .horizontal)
        let hosted = Hosted(session: session)
        defer { hosted.tearDown() }
        await pump(hosted.view, until: { session.paneFrames.frames[survivor] != nil && session.paneFrames.frames[closed] != nil })

        _ = store.closePane(id: closed)
        #expect(session.tree.root.findPane(id: closed) == nil)
        await pump(hosted.view, until: { session.paneFrames.frames[closed] == nil })
        #expect(session.paneFrames.frames[closed] == nil)
        #expect(session.paneFrames.frames[survivor] != nil)
    }

    @Test func hiddenPaneFrameIsDropped() async throws {
        let store = AppStateStore()
        let session = store.sessions[0]
        let survivor = session.focusedPaneAnyKind.id
        let hidden = try split(store, survivor, .horizontal)
        let hosted = Hosted(session: session)
        defer { hosted.tearDown() }
        await pump(hosted.view, until: { session.paneFrames.frames[survivor] != nil && session.paneFrames.frames[hidden] != nil })

        store.hidePane(id: hidden)
        await pump(hosted.view, until: { session.paneFrames.frames[hidden] == nil })
        #expect(session.paneFrames.frames[hidden] == nil)
        #expect(session.paneFrames.frames[survivor] != nil)
    }
}
