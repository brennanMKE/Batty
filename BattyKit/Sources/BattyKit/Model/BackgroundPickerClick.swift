// BackgroundPickerClick.swift

import AppKit

/// What a click on a Background Images cell does. One handler reads the click
/// count, because the second click of a double click must not read as the
/// "click again to cancel" of a downloading pick.
nonisolated enum BackgroundPickerClick: Equatable, Sendable {
    case apply
    case applyAndClose
    case cancelDownload

    static func resolve(clickCount: Int, isDownloadingPendingPick: Bool) -> Self {
        if clickCount >= 2 { return .applyAndClose }
        return isDownloadingPendingPick ? .cancelDownload : .apply
    }

    /// The click count of the mouse event being handled. Only a tap may ask:
    /// `currentEvent` keeps the last mouse event, so an accessibility action
    /// passes one click itself rather than reading a stale double click.
    @MainActor
    static func currentClickCount() -> Int {
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseDown || event.type == .leftMouseUp else { return 1 }
        return event.clickCount
    }
}
