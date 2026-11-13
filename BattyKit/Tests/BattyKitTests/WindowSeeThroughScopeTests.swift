// WindowSeeThroughScopeTests.swift

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import BattyKit

private final class Counts {
    var parentRuns = 0
    var contentRuns = 0
    var lastSeeThrough: Bool?
    var lastPaneCount = 0
    var lastTabCount = 0
}

private struct ContentProbe: View {
    let session: SessionRuntime
    let counts: Counts
    @Environment(\.windowIsSeeThrough) private var isSeeThrough

    var body: some View {
        let panes = session.tree.allPanes
        counts.contentRuns += 1
        counts.lastSeeThrough = isSeeThrough
        counts.lastPaneCount = panes.count
        counts.lastTabCount = panes.first?.tabs.count ?? 0
        return Color.clear
    }
}

private struct ParentProbe: View {
    let store: AppStateStore
    let windowRuntime: WindowRuntime
    let session: SessionRuntime
    let counts: Counts

    var body: some View {
        counts.parentRuns += 1
        return WindowSeeThroughScope(store: store, windowRuntime: windowRuntime) {
            ContentProbe(session: session, counts: counts)
        }
    }
}

/// The shape `RootWindowView` had before the scope: the parent reads the scan.
private struct UnscopedParentProbe: View {
    let store: AppStateStore
    let windowRuntime: WindowRuntime
    let session: SessionRuntime
    let counts: Counts

    var body: some View {
        counts.parentRuns += 1
        let isSeeThrough = store.isWindowSeeThrough(windowRuntime)
        return ContentProbe(session: session, counts: counts)
            .environment(\.windowIsSeeThrough, isSeeThrough)
    }
}

@MainActor
final class WindowSeeThroughScopeTests {
    private static let low = TerminalBackgroundSettings(imagePath: nil, terminalOpacity: 0.4)

    private let testDefaults = TestDefaults()
    private var defaults: UserDefaults { testDefaults.defaults }
    private var hostWindows: [NSWindow] = []

    @MainActor deinit {
        for window in hostWindows { window.contentView = nil }
        testDefaults.tearDown()
    }

    private func makeStore(sessions: [SessionRuntime]) -> AppStateStore {
        AppStateStore(
            sessions: sessions,
            preferences: defaults,
            backgroundGate: .acceptingEveryImage(defaults: defaults)
        )
    }

    private func pane() -> PaneRuntime {
        PaneRuntime(tabBackgroundGate: .acceptingEveryImage(defaults: defaults))
    }

    private func host<V: View>(_ view: V) -> NSView {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        hostWindows.append(window)
        return hosting
    }

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
                DispatchQueue.main.async {
                    continuation.resume()
                }
            }
            view.layoutSubtreeIfNeeded()
        }
        if !condition() {
            Issue.record("Timed out after \(maxTurns) main-queue turns", sourceLocation: sourceLocation)
        }
    }

    private struct Fixture {
        let store: AppStateStore
        let window: WindowRuntime
        let session: SessionRuntime
        let pane: PaneRuntime
        let counts = Counts()
    }

    private func fixture() throws -> Fixture {
        let pane = pane()
        let session = SessionRuntime(tree: SplitTree(root: .leaf(pane)))
        let store = makeStore(sessions: [session])
        return Fixture(store: store, window: try #require(store.windows.first), session: session, pane: pane)
    }

    private func hostScoped(_ f: Fixture) async -> NSView {
        let view = host(ParentProbe(store: f.store, windowRuntime: f.window, session: f.session, counts: f.counts))
        await pump(view) { f.counts.contentRuns > 0 }
        return view
    }

    @Test func harnessDetectsAParentThatReadsTheScan() async throws {
        let f = try fixture()
        let view = host(UnscopedParentProbe(store: f.store, windowRuntime: f.window, session: f.session, counts: f.counts))
        await pump(view) { f.counts.contentRuns > 0 }
        let before = f.counts.parentRuns
        _ = f.session.tree.splitFocusedPane(direction: .horizontal)
        await pump(view) { f.counts.lastPaneCount == 2 }
        #expect(f.counts.parentRuns > before)
    }

    @Test func splittingAnOpaqueSessionDoesNotReevaluateTheScopesParent() async throws {
        let f = try fixture()
        let view = await hostScoped(f)
        let before = f.counts.parentRuns
        _ = f.session.tree.splitFocusedPane(direction: .horizontal)
        await pump(view) { f.counts.lastPaneCount == 2 }
        #expect(f.counts.parentRuns == before)
        #expect(f.counts.lastSeeThrough == false)
    }

    @Test func addingATabInAnOpaqueSessionDoesNotReevaluateTheScopesParent() async throws {
        let f = try fixture()
        let view = await hostScoped(f)
        let before = f.counts.parentRuns
        _ = f.pane.addTab()
        await pump(view) { f.counts.lastTabCount == 2 }
        #expect(f.counts.parentRuns == before)
        #expect(f.counts.lastSeeThrough == false)
    }

    @Test func settingATranslucentTabBackgroundFlipsTheScopedEnvironment() async throws {
        let f = try fixture()
        let view = await hostScoped(f)
        #expect(f.counts.lastSeeThrough == false)
        f.pane.tabs[0].setBackgroundOverride(Self.low)
        await pump(view) { f.counts.lastSeeThrough == true }
    }

    @Test func closingTheLastTranslucentPaneClearsTheScopedEnvironment() async throws {
        let f = try fixture()
        let view = await hostScoped(f)
        _ = f.session.tree.splitFocusedPane(direction: .horizontal)
        f.pane.setBackgroundOverride(Self.low)
        await pump(view) { f.counts.lastSeeThrough == true && f.counts.lastPaneCount == 2 }
        #expect(f.store.closePane(id: f.pane.id) == .closed)
        await pump(view) { f.counts.lastSeeThrough == false }
    }
}
