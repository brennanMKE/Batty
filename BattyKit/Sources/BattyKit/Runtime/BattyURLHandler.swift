// BattyURLHandler.swift

import BattyCLICore
import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "BattyURLHandler")

/// Dispatches `batty://` URLs delivered by the OS to the running app.
///
/// The only supported form right now is `batty://session?path=<abs-path>`,
/// which creates a new Session in the key window at the given directory.
public struct BattyURLHandler {

    /// Handles a `batty://` URL by creating a new Session at the encoded path.
    ///
    /// Called from `BattyAppDelegate.application(_:open:)` on the main actor —
    /// an event-origin callback; safe to write `AppStateStore` observed state.
    @MainActor
    public static func handle(_ url: URL, store: AppStateStore) {
        guard let path = SessionURLBuilder.sessionPath(from: url) else {
            logger.info("Ignoring unrecognized batty:// URL: \(url.absoluteString, privacy: .public)")
            return
        }
        let windowsBefore = store.windows.count
        let registeredBefore = store.registeredContentWindowCount
        logger.debug("BattyURLHandler.handle: path=\(path, privacy: .public) windowRuntimes=\(windowsBefore, privacy: .public) registeredContentWindows=\(registeredBefore, privacy: .public)")
        let session = store.addSession(workingDirectory: path)
        logger.debug("BattyURLHandler.handle: session created id=\(session.id, privacy: .public) windowRuntimes=\(store.windows.count, privacy: .public)")
    }
}
