// BellIntakeTestSupport.swift

import Foundation
@testable import BattyKit

@MainActor
extension AppStateStore {
    /// Rings through the production delegate entry point, with the Tab's
    /// intake wired the way `PaneView`'s `.task` wires it.
    func ringBell(in tab: TabRuntime, times: Int = 1) {
        wireBellReporting(for: tab)
        for _ in 0..<times { tab.terminalDelegate.terminalDidRingBell() }
    }

    func requestDesktopNotification(in tab: TabRuntime, title: String, body: String) {
        wireBellReporting(for: tab)
        tab.terminalDelegate.terminalDidRequestDesktopNotification(title: title, body: body)
    }
}
