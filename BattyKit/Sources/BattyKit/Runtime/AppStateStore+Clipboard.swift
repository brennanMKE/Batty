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
}
