// StableTerminalSurfaceTests.swift

import AppKit
import Foundation
import GhosttyTerminal
import Testing
@testable import BattyKit

@MainActor
struct StableTerminalSurfaceTests {

    @Test func tabStartsWithoutAttachedNSView() {
        let tab = TabRuntime()
        #expect(tab.terminalNSView == nil)
    }

    @Test func attachingNSViewSurvivesContainerSwap() {
        let tab = TabRuntime()
        let terminal = AppTerminalView(frame: .zero)
        terminal.delegate = tab.terminal
        terminal.controller = tab.terminal.controller
        tab.terminalNSView = terminal

        let firstContainer = NSView(frame: .zero)
        firstContainer.addSubview(terminal)
        #expect(terminal.superview === firstContainer)
        #expect(tab.terminalNSView === terminal)

        terminal.removeFromSuperview()
        let secondContainer = NSView(frame: .zero)
        secondContainer.addSubview(terminal)
        #expect(terminal.superview === secondContainer)
        #expect(tab.terminalNSView === terminal)
    }

    @Test func tabRetainsNSViewWhileAlive() {
        let tab = TabRuntime()
        weak var weakTerminal: AppTerminalView?
        autoreleasepool {
            let terminal = AppTerminalView(frame: .zero)
            terminal.delegate = tab.terminal
            tab.terminalNSView = terminal
            weakTerminal = terminal
        }
        #expect(weakTerminal != nil)
        #expect(weakTerminal === tab.terminalNSView)
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
}
