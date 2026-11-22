// SparkleAutoConfirmTests.swift

import BattyXPCCore
import Sparkle
import Testing
@testable import BattyKit

nonisolated struct SparkleAutoConfirmTests {
    private let beta = ServiceNames.Variant.beta.appBundleIdentifier
    private let key = SparkleAutoConfirm.environmentVariable

    @Test func prodIgnoresEveryHookValue() {
        let prod = ServiceNames.Variant.prod.appBundleIdentifier
        #expect(prod == "co.sstools.Batty")
        for value in ["relaunch", "onquit", "garbage", ""] {
            #expect(SparkleAutoConfirm.mode(bundleIdentifier: prod, environment: [key: value]) == nil)
            #expect(SparkleAutoConfirm.unrecognizedValue(bundleIdentifier: prod, environment: [key: value]) == nil)
        }
    }

    @Test func nilOrUnknownBundleIdentifierIgnoresTheHook() {
        for id in [nil, "", "com.example.app", "co.sstools.Batty.beta.extra"] as [String?] {
            for value in ["relaunch", "onquit"] {
                #expect(SparkleAutoConfirm.mode(bundleIdentifier: id, environment: [key: value]) == nil)
            }
        }
    }

    @Test func betaWithHookUnsetOrUnrecognizedIsOff() {
        #expect(SparkleAutoConfirm.mode(bundleIdentifier: beta, environment: [:]) == nil)
        #expect(SparkleAutoConfirm.unrecognizedValue(bundleIdentifier: beta, environment: [:]) == nil)
        for value in ["", "1", "true", "Relaunch", " relaunch", "on-quit", "onQuit"] {
            #expect(SparkleAutoConfirm.mode(bundleIdentifier: beta, environment: [key: value]) == nil)
            #expect(SparkleAutoConfirm.unrecognizedValue(bundleIdentifier: beta, environment: [key: value]) == value)
        }
    }

    @Test func betaRecognizesEachValue() {
        #expect(beta == "co.sstools.Batty.beta")
        #expect(SparkleAutoConfirm.mode(bundleIdentifier: beta, environment: [key: "relaunch"]) == .installAndRelaunch)
        #expect(SparkleAutoConfirm.mode(bundleIdentifier: beta, environment: [key: "onquit"]) == .installOnQuit)
        #expect(SparkleAutoConfirm.unrecognizedValue(bundleIdentifier: beta, environment: [key: "onquit"]) == nil)
    }

    @Test func contractNamesAreStable() {
        #expect(SparkleAutoConfirm.environmentVariable == "BATTY_BETA_SPARKLE_AUTO")
        #expect(SparkleAutoConfirm.checkNotificationName == "co.sstools.Batty.beta.sparkle-auto.check")
        #expect(SparkleAutoConfirm.logPrefix == "sparkle-auto: ")
        #expect(SparkleAutoConfirm.Mode.installAndRelaunch.rawValue == "relaunch")
        #expect(SparkleAutoConfirm.Mode.installOnQuit.rawValue == "onquit")
    }

    @Test func backendIsHeadlessOnlyWithModeAndFeed() {
        #expect(SparkleAutoConfirm.backend(mode: nil, hasFeedURL: true) == .standard)
        #expect(SparkleAutoConfirm.backend(mode: nil, hasFeedURL: false) == .standard)
        #expect(SparkleAutoConfirm.backend(mode: .installAndRelaunch, hasFeedURL: false) == .standard)
        #expect(SparkleAutoConfirm.backend(mode: .installOnQuit, hasFeedURL: false) == .standard)
        #expect(SparkleAutoConfirm.backend(mode: .installAndRelaunch, hasFeedURL: true) == .headless(.installAndRelaunch))
        #expect(SparkleAutoConfirm.backend(mode: .installOnQuit, hasFeedURL: true) == .headless(.installOnQuit))
    }

    @Test func updateFoundInstallsUnlessAlreadyStagedForQuit() {
        let stages: [SPUUserUpdateStage] = [.notDownloaded, .downloaded, .installing]
        for stage in stages {
            #expect(SparkleAutoConfirm.updateFoundChoice(stage: stage, mode: .installAndRelaunch) == .install)
            let expected: SPUUserUpdateChoice = stage == .installing ? .dismiss : .install
            #expect(SparkleAutoConfirm.updateFoundChoice(stage: stage, mode: .installOnQuit) == expected)
        }
    }

    @Test func readyToInstallInstallsInRelaunchModeAndDismissesInOnQuitMode() {
        #expect(SparkleAutoConfirm.readyToInstallChoice(mode: .installAndRelaunch) == .install)
        #expect(SparkleAutoConfirm.readyToInstallChoice(mode: .installOnQuit) == .dismiss)
    }

    @Test func onlyTheHooksOwnCheckIsAllowed() {
        #expect(SparkleAutoConfirm.allowsUpdateCheck(.updates))
        #expect(!SparkleAutoConfirm.allowsUpdateCheck(.updatesInBackground))
        #expect(!SparkleAutoConfirm.allowsUpdateCheck(.updateInformation))
    }
}
