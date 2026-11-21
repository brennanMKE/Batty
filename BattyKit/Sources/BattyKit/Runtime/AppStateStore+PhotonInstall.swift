// AppStateStore+PhotonInstall.swift

import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "AppStateStore+PhotonInstall")

extension AppStateStore {
    /// Settings' Install PhotonHTTP… button (#0693): a terminal Pane split
    /// right of the focused Pane that runs `command`. Focus moves to it so
    /// the user can answer a password prompt. Nil when no window is open.
    public func openPhotonInstallPane(command: String) -> TabRuntime? {
        guard let anchor = focusedPaneIDFallback(), let (window, session) = locate(paneID: anchor) else { return nil }
        let tab = TabRuntime(workingDirectory: NSHomeDirectory())
        let isSessionSelected = window.selectedSessionID == session.id && window.isWindowVisible
        guard let pane = session.tree.splitPane(id: anchor, direction: .horizontal, tabs: [tab], isSessionSelected: isSessionSelected) else { return nil }
        if session.tree.focusedPaneID != pane.id { session.tree.focusedPaneID = pane.id }
        let event = WatchEventPayload(type: "pane_split", sessionID: session.id, targetPaneID: pane.id)
        AppEventWatcher.shared.send(eventType: event.type, payload: event)
        tab.armStartupCommand(command)
        activateWindow(window)
        logger.info("photon install: opened pane \(pane.id, privacy: .public)")
        return tab
    }
}
