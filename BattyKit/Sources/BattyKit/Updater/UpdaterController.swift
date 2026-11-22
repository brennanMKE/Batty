// UpdaterController.swift

import Foundation
import OSLog
import Sparkle

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "UpdaterController")
nonisolated private let autoLogger = Logger(subsystem: Logging.subsystem, category: "SparkleAutoConfirm")

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController`. Disabled
/// entirely when no `SUFeedURL` is set in `Info.plist` — the updater is not
/// started, so no first-launch consent dialogs appear in Beta builds.
///
/// A headless `SPUUpdater` with `SparkleAutoConfirmUserDriver` replaces it only
/// in a Beta with a feed and `BATTY_BETA_SPARKLE_AUTO` set (see
/// `SparkleAutoConfirm`); it checks when the `checkNotificationName`
/// distributed notification arrives.
@MainActor
public final class UpdaterController {
    public static let shared = UpdaterController()

    private enum Running {
        case standard(SPUStandardUpdaterController)
        case headless(SPUUpdater, SparkleAutoConfirmUserDriver)
    }

    private var running: Running
    private var checkObserver: (any NSObjectProtocol)?

    public var isConfigured: Bool {
        guard let url = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else {
            return false
        }
        return !url.isEmpty
    }

    private init() {
        let hasFeedURL = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String).map { !$0.isEmpty } ?? false
        let mode = SparkleAutoConfirm.mode()
        if let value = SparkleAutoConfirm.unrecognizedValue() {
            autoLogger.error("\(SparkleAutoConfirm.logPrefix, privacy: .public)ignored: unrecognized value \"\(value, privacy: .public)\"")
        } else if mode != nil && !hasFeedURL {
            autoLogger.error("\(SparkleAutoConfirm.logPrefix, privacy: .public)ignored: SUFeedURL is empty")
        }

        switch SparkleAutoConfirm.backend(mode: mode, hasFeedURL: hasFeedURL) {
        case .standard:
            self.running = .standard(SPUStandardUpdaterController(
                startingUpdater: hasFeedURL,
                updaterDelegate: nil,
                userDriverDelegate: nil
            ))
        case .headless(let mode):
            let driver = SparkleAutoConfirmUserDriver(mode: mode)
            let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
            do {
                try updater.start()
            } catch {
                let ns = error as NSError
                autoLogger.error("\(SparkleAutoConfirm.logPrefix, privacy: .public)start failed: \(ns.domain, privacy: .public) \(ns.code) \(ns.localizedDescription, privacy: .public)")
                self.running = .standard(SPUStandardUpdaterController(
                    startingUpdater: false,
                    updaterDelegate: nil,
                    userDriverDelegate: nil
                ))
                return
            }
            self.running = .headless(updater, driver)
            checkObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(SparkleAutoConfirm.checkNotificationName),
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    UpdaterController.shared.requestAutoConfirmCheck()
                }
            }
            autoLogger.notice("\(SparkleAutoConfirm.logPrefix, privacy: .public)armed mode=\(mode.rawValue, privacy: .public)")
        }
    }

    /// Creates the updater at launch only when the Beta auto-confirm hook is
    /// set, so Prod and an unhooked Beta create it exactly when they do today.
    public static func armAutoConfirmIfRequested() {
        guard SparkleAutoConfirm.mode() != nil else { return }
        _ = shared
    }

    public func checkForUpdates() {
        guard isConfigured else {
            logger.info("SUFeedURL not set in Info.plist; Check for Updates is disabled")
            return
        }
        switch running {
        case .standard(let controller):
            controller.checkForUpdates(nil)
        case .headless:
            requestAutoConfirmCheck()
        }
    }

    private func requestAutoConfirmCheck() {
        guard case .headless(let updater, _) = running else { return }
        guard updater.canCheckForUpdates else {
            autoLogger.error("\(SparkleAutoConfirm.logPrefix, privacy: .public)check ignored: session in progress")
            return
        }
        autoLogger.notice("\(SparkleAutoConfirm.logPrefix, privacy: .public)check requested")
        updater.checkForUpdates()
    }
}
