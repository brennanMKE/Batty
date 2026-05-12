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
}
