// UpdaterController.swift

import Foundation
import OSLog
import Sparkle

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "UpdaterController")

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController`. Disabled
/// gracefully when no `SUFeedURL` is set in `Info.plist` — early-returns
/// from `checkForUpdates()` so the menu item works as a no-op during
/// development before the appcast is hosted.
@MainActor
public final class UpdaterController {
    public static let shared = UpdaterController()

    public let controller: SPUStandardUpdaterController

    public var isConfigured: Bool {
        guard let url = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else {
            return false
        }
        return !url.isEmpty
    }

    private init() {
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    public func checkForUpdates() {
        guard isConfigured else {
            logger.info("SUFeedURL not set in Info.plist; Check for Updates is disabled")
            return
        }
        controller.checkForUpdates(nil)
    }
}
