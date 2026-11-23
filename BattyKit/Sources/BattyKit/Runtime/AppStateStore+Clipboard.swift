// AppStateStore+Clipboard.swift

import Foundation

extension AppStateStore {
    var clipboardReadPolicy: ClipboardReadPolicy {
        SettingsPreference.resolvedClipboardReadPolicy(defaults: preferences)
    }

    func clipboardRequestContext(forTabID tabID: UUID) -> ClipboardRequestContext {
        for window in windows {
            guard let location = window.locate(tabID: tabID) else { continue }
            let paneIndex = (location.session.tree.allPanes.firstIndex { $0.id == location.pane.id } ?? 0) + 1
            let tabIndex = (location.pane.tabs.firstIndex { $0.id == location.tab.id } ?? 0) + 1
            var processName: String?
            var pid: Int32?
            if let foreground = location.tab.terminalNSView?.foregroundPid, foreground > 0 {
                pid = Int32(foreground)
                processName = ProcessInspector.identity(pid: foreground).name
            }
            return ClipboardRequestContext(
                sessionID: location.session.id,
                sessionTitle: location.session.title,
                tabID: tabID,
                paneID: location.pane.id,
                paneIndex: paneIndex,
                tabLabel: Self.tabLabel(for: location.tab, tabIndex: tabIndex),
                processName: processName,
                pid: pid
            )
        }
        return .unresolved(tabID: tabID)
    }

    /// Routes `tab`'s clipboard confirmations through the app-wide read
    /// Setting, then the owning Session's per-kind policy (#0390, #0674).
    /// Setting the route also forwards any request held before it ran. No
    /// resolvable store, tab or Session denies. `[weak tab]` avoids a retain
    /// cycle: the closure is stored on `tab.terminalDelegate`, which
    /// `TabRuntime` owns. Lives here rather than in `PaneView` so unit tests
    /// exercise the production closure (#0436).
    public func wireClipboardConfirmation(for tab: TabRuntime) {
        tab.terminalDelegate.onClipboardReadConfirmationRequest = { [weak self, weak tab] kind, decide in
            guard let self, let tab else {
                decide(false)
                return
            }
            let session = tab.sessionID.flatMap { self.session(id: $0) }
            routeClipboardConfirmation(
                to: session,
                kind: kind,
                readPolicy: self.clipboardReadPolicy,
                context: self.clipboardRequestContext(forTabID: tab.id),
                decide: decide
            )
        }
    }
}
