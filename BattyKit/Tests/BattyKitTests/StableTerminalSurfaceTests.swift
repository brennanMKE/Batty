// StableTerminalSurfaceTests.swift

import AppKit
import Foundation
import GhosttyTerminal
import Testing
@testable import BattyKit

/// Model-level invariants of the single-host architecture. The visual
/// behaviour (terminal stays painted across navigation) is not testable
/// here — that lives in AppKit's Metal-layer pipeline and SwiftUI's
/// representable lifecycle. These tests instead cover the contract
/// `TerminalHostStore` and `PaneRuntime` honour:
///   * `terminalView(for:)` is idempotent.
///   * Closing a non-active sibling tab leaves the active tab's terminal
///     view alone.
///   * Toggling the active tab does not nil out either tab's terminal view.
///   * Closing a tab releases its terminal view from the host.
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
        let tab = TabRuntime()

        let first = store.terminalView(for: tab)
        let second = store.terminalView(for: tab)

        #expect(first === second)
        #expect(tab.terminalNSView === first)
        #expect(first.superview === store.hostView)
        #expect(store.hasTerminalView(forTabID: tab.id))
    }

    @Test func releasingTerminalViewRemovesItFromTheHost() {
        let store = TerminalHostStore()
        let tab = TabRuntime()
        let view = store.terminalView(for: tab)
        #expect(view.superview === store.hostView)

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
        let tab = TabRuntime()

        // Touch once to create the view, then re-touch many times.
        let original = store.terminalView(for: tab)
        for _ in 0..<10 {
            let again = store.terminalView(for: tab)
            #expect(again === original)
        }
        #expect(tab.terminalNSView === original)
    }

    @Test func updatePlacementsTogglesVisibilityAndAdjustsFrame() {
        let store = TerminalHostStore()
        let tab = TabRuntime()
        let view = store.terminalView(for: tab)
        #expect(view.isHidden)

        store.updatePlacements([
            tab.id: TerminalHostStore.Placement(
                frame: NSRect(x: 10, y: 20, width: 200, height: 100),
                isVisible: true
            )
        ])
        #expect(!view.isHidden)
        #expect(view.frame == NSRect(x: 10, y: 20, width: 200, height: 100))

        store.updatePlacements([
            tab.id: TerminalHostStore.Placement(
                frame: NSRect(x: 10, y: 20, width: 200, height: 100),
                isVisible: false
            )
        ])
        #expect(view.isHidden)

        // A tab missing entirely from the placement map is also hidden.
        store.updatePlacements([:])
        #expect(view.isHidden)
    }
}
