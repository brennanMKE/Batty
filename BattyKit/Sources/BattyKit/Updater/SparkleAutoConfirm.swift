// SparkleAutoConfirm.swift

import BattyXPCCore
import Foundation
import Sparkle

/// Beta-only test seam that lets an automated harness drive a Sparkle update
/// with no UI. Honored only in the Beta bundle and only when
/// `BATTY_BETA_SPARKLE_AUTO` is exactly one of the `Mode` raw values.
nonisolated public enum SparkleAutoConfirm {
    public enum Mode: String, Sendable, Equatable {
        case installAndRelaunch = "relaunch"
        case installOnQuit = "onquit"
    }

    public enum Backend: Equatable, Sendable {
        case standard
        case headless(Mode)
    }

    public static let environmentVariable = "BATTY_BETA_SPARKLE_AUTO"
    public static let checkNotificationName = "co.sstools.Batty.beta.sparkle-auto.check"
    public static let logPrefix = "sparkle-auto: "

    public static func mode(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Mode? {
        // The variant is checked first so Prod never looks at the value.
        guard ServiceNames.Variant(bundleIdentifier: bundleIdentifier) == .beta,
              let value = environment[environmentVariable] else { return nil }
        return Mode(rawValue: value)
    }

    /// The value set in a Beta that is not a recognized mode, for one error log line.
    public static func unrecognizedValue(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard ServiceNames.Variant(bundleIdentifier: bundleIdentifier) == .beta,
              let value = environment[environmentVariable],
              Mode(rawValue: value) == nil else { return nil }
        return value
    }

    public static func backend(mode: Mode?, hasFeedURL: Bool) -> Backend {
        guard let mode, hasFeedURL else { return .standard }
        return .headless(mode)
    }

    /// An update already staged for install-on-quit stays staged in `.installOnQuit`.
    public static func updateFoundChoice(stage: SPUUserUpdateStage, mode: Mode) -> SPUUserUpdateChoice {
        if stage == .installing && mode == .installOnQuit { return .dismiss }
        return .install
    }

    /// Only the hook's own `checkForUpdates()` (`.updates`) may run; Sparkle's
    /// scheduled checks would otherwise install before the trigger.
    public static func allowsUpdateCheck(_ check: SPUUpdateCheck) -> Bool {
        check == .updates
    }

    public static let backgroundCheckRefusedMessage = "background check refused"
    public static let refusalErrorDomain = "co.sstools.Batty.SparkleAutoConfirm"
    public static let refusalErrorDescription = "Batty Beta auto-confirm hook: checks run only when triggered"

    public static func readyToInstallChoice(mode: Mode) -> SPUUserUpdateChoice {
        switch mode {
        case .installAndRelaunch: .install
        case .installOnQuit: .dismiss
        }
    }
}
