// SparkleAutoConfirmUpdaterDelegate.swift

import Foundation
import OSLog
import Sparkle

/// The headless updater's delegate. `SPUUpdater` holds it weakly, so its owner
/// keeps a strong reference.
@MainActor
public final class SparkleAutoConfirmUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    private let sink: SparkleAutoConfirmUserDriver.LogSink

    public init(log: @escaping SparkleAutoConfirmUserDriver.LogSink = SparkleAutoConfirmUserDriver.defaultLog) {
        self.sink = log
    }

    public func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        try decide(updateCheck)
    }

    /// Throwing aborts a scheduled check before the feed is fetched, and Sparkle
    /// shows nothing to the user driver for it.
    func decide(_ check: SPUUpdateCheck) throws {
        guard !SparkleAutoConfirm.allowsUpdateCheck(check) else { return }
        sink(.default, SparkleAutoConfirm.logPrefix + SparkleAutoConfirm.backgroundCheckRefusedMessage)
        // Private domain, code 1: not SUNoUpdateError, which Sparkle treats as "up to date".
        throw NSError(
            domain: SparkleAutoConfirm.refusalErrorDomain,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: SparkleAutoConfirm.refusalErrorDescription]
        )
    }
}
