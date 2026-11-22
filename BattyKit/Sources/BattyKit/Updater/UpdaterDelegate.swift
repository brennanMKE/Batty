// UpdaterDelegate.swift

import Foundation
import OSLog
import Sparkle

/// The delegate of both updater backends. `SPUUpdater` and
/// `SPUStandardUpdaterController` hold it weakly, so its owner keeps a strong
/// reference.
///
/// `updater(_:willInstallUpdate:)` runs in the app before Sparkle's installer
/// sends the quit Apple Event for an immediate install, so it marks that quit
/// as already confirmed. The headless backend also refuses Sparkle's
/// scheduled checks.
@MainActor
public final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    private let sink: SparkleAutoConfirmUserDriver.LogSink
    private let preconfirmedQuit: PreconfirmedQuit
    private let refusesBackgroundChecks: Bool

    public init(
        preconfirmedQuit: PreconfirmedQuit = .shared,
        refusesBackgroundChecks: Bool,
        log: @escaping SparkleAutoConfirmUserDriver.LogSink = SparkleAutoConfirmUserDriver.defaultLog
    ) {
        self.preconfirmedQuit = preconfirmedQuit
        self.refusesBackgroundChecks = refusesBackgroundChecks
        self.sink = log
    }

    public func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        try decide(updateCheck)
    }

    public func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        preconfirmedQuit.mark(.sparkleInstall)
    }

    public func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        preconfirmedQuit.clear()
    }

    /// Throwing aborts a scheduled check before the feed is fetched, and Sparkle
    /// shows nothing to the user driver for it.
    func decide(_ check: SPUUpdateCheck) throws {
        guard refusesBackgroundChecks, !SparkleAutoConfirm.allowsUpdateCheck(check) else { return }
        sink(.default, SparkleAutoConfirm.logPrefix + SparkleAutoConfirm.backgroundCheckRefusedMessage)
        // Private domain, code 1: not SUNoUpdateError, which Sparkle treats as "up to date".
        throw NSError(
            domain: SparkleAutoConfirm.refusalErrorDomain,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: SparkleAutoConfirm.refusalErrorDescription]
        )
    }
}
