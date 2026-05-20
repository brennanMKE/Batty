// UpdaterController.swift

import Foundation
import OSLog
import Sparkle

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "UpdaterController")

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController`. Disabled
/// entirely when no `SUFeedURL` is set in `Info.plist` — the updater is not
/// started, so no first-launch consent dialogs appear in Beta builds.
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
        let hasFeedURL = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String).map { !$0.isEmpty } ?? false
        self.controller = SPUStandardUpdaterController(
            startingUpdater: hasFeedURL,
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
