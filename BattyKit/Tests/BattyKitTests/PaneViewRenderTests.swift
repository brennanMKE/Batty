// PaneViewRenderTests.swift

import AppKit
import SwiftUI
import Testing
@testable import BattyKit

/// Hosts the real `SplitContainerView` -> `PaneView` hierarchy in an
/// `NSHostingView` and reads back the production `PaneFramePreferenceKey`
/// geometry (the same key `SessionRuntime.focusPane(adjacent:)` reads via
/// `session.paneFrames` in `PaneFocus.swift`) to prove a split actually
/// re-renders the live view tree with a real, allotted, non-degenerate
/// frame per Pane — a layer no other test in this suite reaches.
///
/// This proves the split slot each Pane is allotted, not what draws inside
/// it: `PaneFramePreferenceKey` is emitted by `PaneView`'s outer
/// `.frame(allottedSize)` wrapper regardless of the kind-switch's content,
/// so geometry alone can't distinguish an allotted-but-empty slot from one
/// with real content. Not confirmed in-process: `accessibilityChildren()`
/// returned no descendants for an `NSHostingView` whose window was never
/// ordered into the window server, so verifying actual content that way
/// was not pursued further.
@MainActor
struct PaneViewRenderTests {

    private struct HostedSession: View {
        let session: SessionRuntime
        let windowID: WindowID
        @Binding var frames: [UUID: CGRect]

        var body: some View {
            SplitContainerView(tree: session.tree)
                .coordinateSpace(name: "session")
                .onPreferenceChange(PaneFramePreferenceKey.self) { frames = $0 }
                .environment(\.windowID, windowID)
                .frame(width: 1200, height: 800)
        }
    }

    /// `NSWindow` is never ordered into the window server (mirrors
    /// `AtlasOwnershipExperimentTests.attachSurface`) — assigning
    /// `contentView` is sufficient for AppKit/SwiftUI to run a real layout
    /// pass without putting anything on screen.
    private func host<Content: View>(
        _ content: Content,
        size: CGSize
    ) -> (window: NSWindow, view: NSHostingView<Content>) {
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.contentView = hostingView
        return (window, hostingView)
    }

    private func pump(_ view: NSView, until condition: () -> Bool, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        view.layoutSubtreeIfNeeded()
    }

    @Test func splitRerendersTheHostedTreeWithAllottedNonDegenerateGeometry() throws {
        let store = AppStateStore()
        let session = store.sessions[0]
        let terminalPane = session.focusedPaneAnyKind
        let windowWidth: CGFloat = 1200

        let windowID = WindowID()
        var frames: [UUID: CGRect] = [:]
        let binding = Binding<[UUID: CGRect]>(get: { frames }, set: { frames = $0 })
        let (window, hostingView) = host(
            HostedSession(session: session, windowID: windowID, frames: binding),
            size: CGSize(width: windowWidth, height: 800)
        )
        // Runs on every exit path, including a `#require` failure partway
        // through — reads `session.tree.allPanes` at defer time (not a
        // snapshot taken earlier) so the split-added pane's tab is covered
        // too. Keeps `window` alive until cleanup runs.
        defer {
            for pane in session.tree.allPanes {
                for tab in pane.tabs {
                    TerminalHostStore.shared.releaseTerminalView(forTabID: tab.id)
                }
            }
            TerminalHostStore.shared.releaseHost(forWindowID: windowID)
            _ = window
        }

        pump(hostingView, until: { frames[terminalPane.id] != nil })
        let soloFrame = try #require(frames[terminalPane.id])
        #expect(soloFrame.width > windowWidth * 0.9)

        // The production entry point behind `batty pane split --view <kind>`
        // (AppStateStore.splitPane -> SplitTree.splitPane) mutates the same
        // SplitTree instance already hosted above, without recreating the
        // hosting view — this is what actually exercises whether the live
        // view tree re-renders over a topology change, not just whether the
        // model mutated.
        // contentFactory: { _ in nil } routes the new pane through
        // PaneContentPlaceholderView instead of a real GitStatusPaneContent,
        // so this doesn't also start a real FSEventStream watcher as a side
        // effect of a geometry-only assertion.
        let splitResult = store.splitPane(id: terminalPane.id, direction: .horizontal, kind: .gitStatus, contentFactory: { _ in nil })
        let newPaneID = try #require(splitResult)

        pump(hostingView, until: { frames[terminalPane.id] != nil && frames[newPaneID] != nil })
        let terminalFrame = try #require(frames[terminalPane.id])
        let typedFrame = try #require(frames[newPaneID])

        #expect(terminalFrame.width > 0)
        #expect(typedFrame.width > 0)
        #expect(terminalFrame.width < windowWidth * 0.75)
        #expect(typedFrame.width > windowWidth * 0.25)
        #expect(abs((terminalFrame.width + typedFrame.width) - windowWidth) < 40)
    }
}
