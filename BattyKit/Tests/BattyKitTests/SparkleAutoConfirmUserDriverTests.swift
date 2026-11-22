// SparkleAutoConfirmUserDriverTests.swift

import Foundation
import OSLog
import Sparkle
import Testing
@testable import BattyKit

@MainActor
struct SparkleAutoConfirmUserDriverTests {
    private final class LogBox {
        var lines: [(OSLogType, String)] = []
        var messages: [String] { lines.map(\.1) }
    }

    private func makeDriver(_ mode: SparkleAutoConfirm.Mode) -> (SparkleAutoConfirmUserDriver, LogBox) {
        let box = LogBox()
        let driver = SparkleAutoConfirmUserDriver(mode: mode) { box.lines.append(($0, $1)) }
        return (driver, box)
    }

    private func p(_ s: String) -> String { SparkleAutoConfirm.logPrefix + s }

    @Test func readyToInstallRepliesInstallInRelaunchMode() {
        let (driver, box) = makeDriver(.installAndRelaunch)
        var replies: [SPUUserUpdateChoice] = []
        driver.showReady(toInstallAndRelaunch: { replies.append($0) })
        #expect(replies == [.install])
        #expect(box.messages == [p("ready to install"), p("installing and relaunching")])
    }

    @Test func readyToInstallRepliesDismissInOnQuitMode() {
        let (driver, box) = makeDriver(.installOnQuit)
        var replies: [SPUUserUpdateChoice] = []
        driver.showReady(toInstallAndRelaunch: { replies.append($0) })
        #expect(replies == [.dismiss])
        #expect(box.messages == [p("ready to install"), p("staged for install on quit")])
    }

    @Test func permissionRequestTurnsAutomaticChecksOff() {
        let (driver, _) = makeDriver(.installAndRelaunch)
        var responses: [SUUpdatePermissionResponse] = []
        driver.show(SPUUpdatePermissionRequest(systemProfile: []), reply: { responses.append($0) })
        #expect(responses.count == 1)
        #expect(responses.first?.automaticUpdateChecks == false)
        #expect(responses.first?.sendSystemProfile == false)
    }

    @Test func updaterErrorIsLoggedAtErrorAndAcknowledgedOnce() {
        let (driver, box) = makeDriver(.installAndRelaunch)
        var acks = 0
        driver.showUpdaterError(NSError(domain: "SUSparkleErrorDomain", code: 4005), acknowledgement: { acks += 1 })
        #expect(acks == 1)
        #expect(box.lines.count == 1)
        #expect(box.lines.first?.0 == .error)
        #expect(box.messages.first?.contains("SUSparkleErrorDomain 4005") == true)
    }

    @Test func updateNotFoundIsLoggedAndAcknowledged() {
        let (driver, box) = makeDriver(.installOnQuit)
        var acks = 0
        driver.showUpdateNotFoundWithError(NSError(domain: "SUSparkleErrorDomain", code: 1001), acknowledgement: { acks += 1 })
        #expect(acks == 1)
        #expect(box.messages.count == 1)
        #expect(box.messages.first?.hasPrefix(p("no update: ")) == true)
    }

    @Test func installingWithAppStillRunningNeverRetries() {
        let (driver, box) = makeDriver(.installAndRelaunch)
        var retries = 0
        driver.showInstallingUpdate(withApplicationTerminated: false, retryTerminatingApplication: { retries += 1 })
        #expect(retries == 0)
        #expect(box.messages == [p("installing applicationTerminated=false")])
    }

    @Test func installedAndDismissedAreLogged() {
        let (driver, box) = makeDriver(.installAndRelaunch)
        var acks = 0
        driver.showUpdateInstalledAndRelaunched(true, acknowledgement: { acks += 1 })
        driver.dismissUpdateInstallation()
        #expect(acks == 1)
        #expect(box.messages == [p("installed relaunched=true"), p("dismissed")])
    }

    @Test func progressCallbacksLogNothing() {
        let (driver, box) = makeDriver(.installAndRelaunch)
        driver.showDownloadDidReceiveExpectedContentLength(1000)
        driver.showDownloadDidReceiveData(ofLength: 10)
        driver.showExtractionReceivedProgress(0.5)
        #expect(box.lines.isEmpty)
    }

    @Test func everyLineCarriesThePrefix() {
        let (driver, box) = makeDriver(.installOnQuit)
        driver.show(SPUUpdatePermissionRequest(systemProfile: []), reply: { _ in })
        driver.showDownloadInitiated(cancellation: {})
        driver.showDownloadDidStartExtractingUpdate()
        driver.showReady(toInstallAndRelaunch: { _ in })
        driver.showInstallingUpdate(withApplicationTerminated: true, retryTerminatingApplication: {})
        driver.showUpdaterError(NSError(domain: "D", code: 1), acknowledgement: {})
        driver.showUpdateNotFoundWithError(NSError(domain: "D", code: 2), acknowledgement: {})
        driver.showUpdateInstalledAndRelaunched(false, acknowledgement: {})
        driver.dismissUpdateInstallation()
        #expect(box.lines.count == 10)
        #expect(box.messages.allSatisfy { $0.hasPrefix(SparkleAutoConfirm.logPrefix) })
    }
}
