// StableTerminalSurfaceTests.swift

import AppKit
import Foundation
import GhosttyTerminal
import Testing
@testable import BattyKit

/// Model-level invariants of the per-window host architecture. The visual
/// behaviour (terminal stays painted across navigation) is not testable
/// here — that lives in AppKit's Metal-layer pipeline and SwiftUI's
/// representable lifecycle. These tests instead cover the contract
/// `TerminalHostStore` and `PaneRuntime` honour:
///   * `terminalView(for:windowID:)` is idempotent.
///   * Closing a non-active sibling tab leaves the active tab's terminal
///     view alone.
///   * Toggling the active tab does not nil out either tab's terminal view.
///   * Closing a tab releases its terminal view from the host.
///   * One host is created per window ID.
///   * A host is released only after all its tabs are gone.
@MainActor
struct StableTerminalSurfaceTests {

    @Test func tabStartsWithoutAttachedNSView() {
        let store = TerminalHostStore()
        let tab = TabRuntime()
        #expect(tab.terminalNSView == nil)
        #expect(store.hasTerminalView(forTabID: tab.id) == false)
    }

    @Test func terminalViewForTabIsIdempotent() {
        let store = TerminalHostStore()
        let windowID = WindowID()
        let tab = TabRuntime()

        let first = store.terminalView(for: tab, windowID: windowID)
        let second = store.terminalView(for: tab, windowID: windowID)

        #expect(first === second)
        #expect(tab.terminalNSView === first)
        let host = store.hostView(forWindowID: windowID)
        #expect(first.superview === host)
        #expect(store.hasTerminalView(forTabID: tab.id))
    }

    @Test func releasingTerminalViewRemovesItFromTheHost() {
        let store = TerminalHostStore()
        let windowID = WindowID()
        let tab = TabRuntime()
        let view = store.terminalView(for: tab, windowID: windowID)
        let host = store.hostView(forWindowID: windowID)
        #expect(view.superview === host)

        store.releaseTerminalView(forTabID: tab.id)

        #expect(view.superview == nil)
        #expect(store.hasTerminalView(forTabID: tab.id) == false)
    }

    /// Closing a non-active sibling tab must leave the active tab's
    /// `terminalNSView` reference untouched — the wrapper's invariants
    /// only attach views; `removeTab` operates on the model only.
    @Test func removingNonActiveTabPreservesActiveTabNSView() {
        let activeTab = TabRuntime()
        let siblingTab = TabRuntime()
        let activeNSView = AppTerminalView(frame: .zero)
        activeNSView.delegate = activeTab.terminal
        activeTab.terminalNSView = activeNSView
        let siblingNSView = AppTerminalView(frame: .zero)
        siblingNSView.delegate = siblingTab.terminal
        siblingTab.terminalNSView = siblingNSView

        let pane = PaneRuntime(tabs: [activeTab, siblingTab])
        pane.activeTabID = activeTab.id

        pane.removeTab(id: siblingTab.id)

        #expect(activeTab.terminalNSView === activeNSView)
        #expect(pane.activeTabID == activeTab.id)
        #expect(pane.tabs.count == 1)
    }

    /// Toggling the pane's active tab between two siblings must not nil-out
    /// either tab's `terminalNSView`. Both PTYs must survive a focus flip.
    @Test func togglingActiveTabPreservesBothNSViewReferences() {
        let firstTab = TabRuntime()
        let secondTab = TabRuntime()
        let firstNSView = AppTerminalView(frame: .zero)
        firstNSView.delegate = firstTab.terminal
        firstTab.terminalNSView = firstNSView
        let secondNSView = AppTerminalView(frame: .zero)
        secondNSView.delegate = secondTab.terminal
        secondTab.terminalNSView = secondNSView

        let pane = PaneRuntime(tabs: [firstTab, secondTab])
        pane.activeTabID = firstTab.id

        pane.activeTabID = secondTab.id
        #expect(firstTab.terminalNSView === firstNSView)
        #expect(secondTab.terminalNSView === secondNSView)

        pane.activeTabID = firstTab.id
        #expect(firstTab.terminalNSView === firstNSView)
        #expect(secondTab.terminalNSView === secondNSView)
    }

    /// Re-asserting the same selection (selected session, focused pane,
    /// active tab) must not trigger any new terminal-view creation.
    /// This is the core architectural invariant: navigation is pure
    /// data mutation, never a "rebuild a new NSView" path.
    @Test func reassertingSelectionDoesNotCreateNewTerminalViews() {
        let store = TerminalHostStore()
        let windowID = WindowID()
        let tab = TabRuntime()

        // Touch once to create the view, then re-touch many times.
        let original = store.terminalView(for: tab, windowID: windowID)
        for _ in 0..<10 {
            let again = store.terminalView(for: tab, windowID: windowID)
            #expect(again === original)
        }
        #expect(tab.terminalNSView === original)
    }

    /// `setPlacement` updates one tab without disturbing its siblings.
    /// This is the geometry-settling backstop for #0101 — called from
    /// `TerminalPlaceholderView.onGeometryChange` per visible tab.
    @Test func setPlacementForSingleTabPreservesSiblings() {
        let store = TerminalHostStore()
        let windowID = WindowID()
        let firstTab = TabRuntime()
        let secondTab = TabRuntime()
        let firstView = store.terminalView(for: firstTab, windowID: windowID)
        let secondView = store.terminalView(for: secondTab, windowID: windowID)

        store.updatePlacements([
            firstTab.id: TerminalHostStore.Placement(
                frame: NSRect(x: 0, y: 0, width: 100, height: 100),
                isVisible: true
            ),
            secondTab.id: TerminalHostStore.Placement(
                frame: NSRect(x: 0, y: 0, width: 200, height: 200),
                isVisible: true
            )
        ], forWindowID: windowID)
        #expect(firstView.frame == NSRect(x: 0, y: 0, width: 100, height: 100))
        #expect(secondView.frame == NSRect(x: 0, y: 0, width: 200, height: 200))

        store.setPlacement(
            TerminalHostStore.Placement(
                frame: NSRect(x: 0, y: 0, width: 300, height: 300),
                isVisible: true
            ),
            forTabID: firstTab.id
        )

        #expect(firstView.frame == NSRect(x: 0, y: 0, width: 300, height: 300))
        #expect(secondView.frame == NSRect(x: 0, y: 0, width: 200, height: 200))
        #expect(!firstView.isHidden)
        #expect(!secondView.isHidden)
    }

    @Test func setPlacementHidesWhenIsVisibleFalse() {
        let store = TerminalHostStore()
        let windowID = WindowID()
        let tab = TabRuntime()
        let view = store.terminalView(for: tab, windowID: windowID)

        store.setPlacement(
            TerminalHostStore.Placement(
                frame: NSRect(x: 0, y: 0, width: 100, height: 100),
                isVisible: true
            ),
            forTabID: tab.id
        )
        #expect(!view.isHidden)

        store.setPlacement(
            TerminalHostStore.Placement(
                frame: NSRect(x: 0, y: 0, width: 100, height: 100),
                isVisible: false
            ),
            forTabID: tab.id
        )
        #expect(view.isHidden)
    }

    @Test func updatePlacementsTogglesVisibilityAndAdjustsFrame() {
        let store = TerminalHostStore()
        let windowID = WindowID()
        let tab = TabRuntime()
        let view = store.terminalView(for: tab, windowID: windowID)
        #expect(view.isHidden)

        store.updatePlacements([
            tab.id: TerminalHostStore.Placement(
                frame: NSRect(x: 10, y: 20, width: 200, height: 100),
                isVisible: true
            )
        ], forWindowID: windowID)
        #expect(!view.isHidden)
        #expect(view.frame == NSRect(x: 10, y: 20, width: 200, height: 100))

        store.updatePlacements([
            tab.id: TerminalHostStore.Placement(
                frame: NSRect(x: 10, y: 20, width: 200, height: 100),
                isVisible: false
            )
        ], forWindowID: windowID)
        #expect(view.isHidden)

        // A tab missing entirely from the placement map is also hidden.
        store.updatePlacements([:], forWindowID: windowID)
        #expect(view.isHidden)
    }

    // MARK: - Per-window host registry tests (new in #0236)

    /// Each WindowID gets its own dedicated TerminalHostView.
    @Test func eachWindowIDGetsItsOwnHost() {
        let store = TerminalHostStore()
        let window1 = WindowID()
        let window2 = WindowID()

        let host1 = store.hostView(forWindowID: window1)
        let host2 = store.hostView(forWindowID: window2)

        #expect(host1 !== host2)
    }

    /// Requesting the host for the same WindowID is idempotent.
    @Test func hostViewForSameWindowIDIsIdempotent() {
        let store = TerminalHostStore()
        let windowID = WindowID()

        let first = store.hostView(forWindowID: windowID)
        let second = store.hostView(forWindowID: windowID)

        #expect(first === second)
    }

    /// A terminal view is added to the host for its window, not a sibling window's host.
    @Test func terminalViewAddedToCorrectWindowHost() {
        let store = TerminalHostStore()
        let window1 = WindowID()
        let window2 = WindowID()
        let tab1 = TabRuntime()
        let tab2 = TabRuntime()

        let view1 = store.terminalView(for: tab1, windowID: window1)
        let view2 = store.terminalView(for: tab2, windowID: window2)

        let host1 = store.hostView(forWindowID: window1)
        let host2 = store.hostView(forWindowID: window2)

        #expect(view1.superview === host1)
        #expect(view2.superview === host2)
        #expect(view1.superview !== host2)
        #expect(view2.superview !== host1)
    }

    /// updatePlacements scoped to window1 does not affect views in window2.
    @Test func updatePlacementsDoesNotCrossBetweenWindows() {
        let store = TerminalHostStore()
        let window1 = WindowID()
        let window2 = WindowID()
        let tab1 = TabRuntime()
        let tab2 = TabRuntime()

        let view1 = store.terminalView(for: tab1, windowID: window1)
        let view2 = store.terminalView(for: tab2, windowID: window2)

        // Make view2 visible first so we can verify it doesn't get hidden.
        store.setPlacement(
            TerminalHostStore.Placement(frame: NSRect(x: 0, y: 0, width: 100, height: 100), isVisible: true),
            forTabID: tab2.id
        )
        #expect(!view2.isHidden)

        // Update placements for window1 only (empty — should hide view1).
        store.updatePlacements([:], forWindowID: window1)

        // view1 should now be hidden (no placement in its window's map).
        #expect(view1.isHidden)
        // view2 must remain visible — different window, not touched.
        #expect(!view2.isHidden)
    }

    /// releaseHost succeeds only after all tabs in the window have been released.
    /// If tabs remain, the host is kept (teardown gating).
    @Test func releaseHostIsGatedOnTabRelease() {
        let store = TerminalHostStore()
        let windowID = WindowID()
        let tab = TabRuntime()

        _ = store.terminalView(for: tab, windowID: windowID)
        let host = store.hostView(forWindowID: windowID)
        #expect(host === store.hostView(forWindowID: windowID))

        // Release attempt while tab is still live — host must stay.
        store.releaseHost(forWindowID: windowID)
        #expect(host === store.hostView(forWindowID: windowID))

        // Release the tab, then release the host — host should be gone.
        store.releaseTerminalView(forTabID: tab.id)
        store.releaseHost(forWindowID: windowID)

        // A new call creates a fresh host (different instance).
        let newHost = store.hostView(forWindowID: windowID)
        #expect(newHost !== host)
    }

    /// After all a window's tabs are released, releaseHost removes the entry.
    @Test func releaseHostRemovesRegistryEntry() {
        let store = TerminalHostStore()
        let windowID = WindowID()
        let tab1 = TabRuntime()
        let tab2 = TabRuntime()

        _ = store.terminalView(for: tab1, windowID: windowID)
        _ = store.terminalView(for: tab2, windowID: windowID)

        store.releaseTerminalView(forTabID: tab1.id)
        // One tab remains — host not released.
        store.releaseHost(forWindowID: windowID)

        store.releaseTerminalView(forTabID: tab2.id)
        // No tabs remain — host released now.
        store.releaseHost(forWindowID: windowID)

        // Requesting the host again creates a brand-new instance.
        let recycled = store.hostView(forWindowID: windowID)
        #expect(recycled.subviews.isEmpty)
    }
}
