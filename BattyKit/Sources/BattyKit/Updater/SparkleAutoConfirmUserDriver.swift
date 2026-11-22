// SparkleAutoConfirmUserDriver.swift

import Foundation
import OSLog
import Sparkle

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "SparkleAutoConfirm")

/// A Sparkle user driver with no UI: it answers every prompt at once according
/// to the `SparkleAutoConfirm.Mode` and logs each step with
/// `SparkleAutoConfirm.logPrefix`, so a harness can wait on log lines.
@MainActor
public final class SparkleAutoConfirmUserDriver: NSObject, SPUUserDriver {
    public typealias LogSink = (OSLogType, String) -> Void

    public static let defaultLog: LogSink = { type, message in
        logger.log(level: type, "\(message, privacy: .public)")
    }

    private let mode: SparkleAutoConfirm.Mode
    private let sink: LogSink

    public init(mode: SparkleAutoConfirm.Mode, log: @escaping LogSink = SparkleAutoConfirmUserDriver.defaultLog) {
        self.mode = mode
        self.sink = log
    }

    private func log(_ message: String, _ type: OSLogType = .default) {
        sink(type, SparkleAutoConfirm.logPrefix + message)
    }

    public func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        log("permission request answered: automatic checks off")
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    public func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    public func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        log("update found version=\(appcastItem.displayVersionString) build=\(appcastItem.versionString) stage=\(Self.name(of: state.stage))")
        reply(SparkleAutoConfirm.updateFoundChoice(stage: state.stage, mode: mode))
    }

    public func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    public func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    public func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        log("no update: \(error.localizedDescription)")
        acknowledgement()
    }

    public func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        let ns = error as NSError
        log("error: \(ns.domain) \(ns.code) \(ns.localizedDescription)", .error)
        acknowledgement()
    }

    public func showDownloadInitiated(cancellation: @escaping () -> Void) {
        log("downloading")
    }

    public func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}

    public func showDownloadDidReceiveData(ofLength length: UInt64) {}

    public func showDownloadDidStartExtractingUpdate() {
        log("extracting")
    }

    public func showExtractionReceivedProgress(_ progress: Double) {}

    public func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        log("ready to install")
        switch mode {
        case .installAndRelaunch: log("installing and relaunching")
        case .installOnQuit: log("staged for install on quit")
        }
        reply(SparkleAutoConfirm.readyToInstallChoice(mode: mode))
    }

    /// Never calls `retryTerminatingApplication`: the hook does not retry.
    public func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        log("installing applicationTerminated=\(applicationTerminated)")
    }

    public func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        log("installed relaunched=\(relaunched)")
        acknowledgement()
    }

    public func showUpdateInFocus() {}

    public func dismissUpdateInstallation() {
        log("dismissed")
    }

    private static func name(of stage: SPUUserUpdateStage) -> String {
        switch stage {
        case .notDownloaded: "notDownloaded"
        case .downloaded: "downloaded"
        case .installing: "installing"
        @unknown default: "unknown(\(stage.rawValue))"
        }
    }
}
