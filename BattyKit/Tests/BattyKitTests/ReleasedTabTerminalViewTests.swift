// ReleasedTabTerminalViewTests.swift

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import BattyKit

/// A released tab id never gets a terminal view or a placement again,
/// even when a closing Pane's placeholder body is evaluated after the
/// close (#0535).
@MainActor
struct ReleasedTabTerminalViewTests {

    @Test func terminalViewForAReleasedTabCreatesNothing() throws {
        let store = TerminalHostStore()
        let windowID = WindowID()
        let tab = TabRuntime()
        _ = try #require(store.terminalView(for: tab, windowID: windowID))
        store.releaseTerminalView(forTabID: tab.id)
        let host = store.hostView(forWindowID: windowID)
        let subviewCount = host.subviews.count
        let sessionCount = store.terminalSessionCount

        let view = store.terminalView(for: tab, windowID: windowID)

        #expect(view == nil)
        #expect(store.hasTerminalView(forTabID: tab.id) == false)
        #expect(host.subviews.count == subviewCount)
        #expect(tab.terminalNSView == nil)
        #expect(store.terminalSessionCount == sessionCount)
    }

    @Test func terminalViewForATabReleasedBeforeItsViewExistedCreatesNothing() {
        let store = TerminalHostStore()
        let windowID = WindowID()
        let tab = TabRuntime()
        let host = store.hostView(forWindowID: windowID)
        store.releaseTerminalView(forTabID: tab.id)

        let view = store.terminalView(for: tab, windowID: windowID)

        #expect(view == nil)
        #expect(host.subviews.isEmpty)
        #expect(store.hasTerminalView(forTabID: tab.id) == false)
    }

    @Test func releasingOneTabDoesNotBlockViewsForOtherTabs() throws {
        let store = TerminalHostStore()
        let windowID = WindowID()
        let tabA = TabRuntime()
        let tabB = TabRuntime()
        _ = store.terminalView(for: tabA, windowID: windowID)
        store.releaseTerminalView(forTabID: tabA.id)

        let first = try #require(store.terminalView(for: tabB, windowID: windowID))
        let second = store.terminalView(for: tabB, windowID: windowID)

        #expect(first === second)
        #expect(store.hasTerminalView(forTabID: tabB.id))
    }

    @Test func setPlacementForAReleasedTabRecordsNothing() {
        let store = TerminalHostStore()
        let windowID = WindowID()
        let tab = TabRuntime()
        _ = store.terminalView(for: tab, windowID: windowID)
        store.releaseTerminalView(forTabID: tab.id)

        store.setPlacement(
            TerminalHostStore.Placement(frame: CGRect(x: 10, y: 20, width: 300, height: 200), isVisible: true),
            forTabID: tab.id
        )

        #expect(store.placement(forTabID: tab.id) == nil)
    }

    @Test func updatePlacementsSkipsReleasedTabs() throws {
        let store = TerminalHostStore()
        let windowID = WindowID()
        let tabA = TabRuntime()
        let tabB = TabRuntime()
        _ = store.terminalView(for: tabA, windowID: windowID)
        let viewB = try #require(store.terminalView(for: tabB, windowID: windowID))
        store.releaseTerminalView(forTabID: tabA.id)
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)

        store.updatePlacements([
            tabA.id: TerminalHostStore.Placement(frame: frame, isVisible: true),
            tabB.id: TerminalHostStore.Placement(frame: frame, isVisible: true),
        ], forWindowID: windowID)

        #expect(store.placement(forTabID: tabA.id) == nil)
        #expect(store.placement(forTabID: tabB.id) != nil)
        #expect(viewB.isHidden == false)
        #expect(viewB.frame == frame)
    }

    @Test func placeholderBodyCreatesTheTerminalViewOnFirstMount() {
        let shared = TerminalHostStore.shared
        let tab = TabRuntime()
        defer { shared.releaseTerminalView(forTabID: tab.id) }

        let hosted = mountPlaceholder(for: tab, windowID: WindowID())

        #expect(shared.hasTerminalView(forTabID: tab.id))
        #expect(tab.terminalNSView != nil)
        _ = hosted
    }

    @Test func placeholderBodyForAReleasedTabDoesNotRecreateItsTerminalView() {
        let shared = TerminalHostStore.shared
        let windowID = WindowID()
        let tab = TabRuntime()
        defer { shared.releaseTerminalView(forTabID: tab.id) }
        _ = shared.terminalView(for: tab, windowID: windowID)
        shared.releaseTerminalView(forTabID: tab.id)

        let hosted = mountPlaceholder(for: tab, windowID: windowID)

        #expect(shared.hasTerminalView(forTabID: tab.id) == false)
        #expect(tab.terminalNSView == nil)
        _ = hosted
    }

    /// Hosts the placeholder in a never-ordered borderless window (the
    /// `PaneViewRenderTests.host` pattern) and lays it out synchronously,
    /// which evaluates its `body`.
    private func mountPlaceholder(for tab: TabRuntime, windowID: WindowID) -> NSWindow {
        let content = TerminalPlaceholderView(tab: tab, isVisible: true, paneID: UUID(), isPaneFocused: true)
            .environment(\.windowID, windowID)
        let size = CGSize(width: 400, height: 300)
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        return window
    }
}
