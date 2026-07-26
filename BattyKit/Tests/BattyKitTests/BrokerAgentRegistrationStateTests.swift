// BrokerAgentRegistrationStateTests.swift

import Foundation
import ServiceManagement
import Testing
@testable import BattyKit

/// Pure mapping tests for `BrokerAgentRegistrationState(status:)` (#0270) —
/// no `SMAppService` registration involved, no XPC, no broker process.
struct BrokerAgentRegistrationStateTests {
    @Test func mapsNotRegistered() {
        #expect(BrokerAgentRegistrationState(status: .notRegistered) == .notRegistered)
    }

    @Test func mapsNotFoundToNotRegistered() {
        // `.notFound` and `.notRegistered` both mean "nothing to distrust
        // yet" from the UI's point of view — neither implies the broker was
        // ever reachable.
        #expect(BrokerAgentRegistrationState(status: .notFound) == .notRegistered)
    }

    @Test func mapsRequiresApproval() {
        #expect(BrokerAgentRegistrationState(status: .requiresApproval) == .requiresApproval)
    }

    @Test func mapsEnabled() {
        #expect(BrokerAgentRegistrationState(status: .enabled) == .enabled)
    }
}

/// `BrokerAgentController.resolvedPlistName` (#0277): the app always has a
/// real `Bundle.main`, unlike the broker/CLI bare Mach-Os, so it derives
/// its own variant's plist name at runtime instead of baking one in.
struct BrokerAgentControllerResolvedPlistNameTests {
    @Test func resolvesProdsPlistNameForAProdBundleIdentifier() {
        #expect(BrokerAgentController.resolvedPlistName(bundleIdentifier: "co.sstools.Batty") == "co.sstools.Batty.broker.plist")
    }

    @Test func resolvesBetasDistinctPlistNameForABetaBundleIdentifier() {
        #expect(BrokerAgentController.resolvedPlistName(bundleIdentifier: "co.sstools.Batty.beta") == "co.sstools.Batty.beta.broker.plist")
    }

    @Test func fallsBackToProdsPlistNameForAnUnrecognizedBundleIdentifier() {
        #expect(BrokerAgentController.resolvedPlistName(bundleIdentifier: "com.example.SomeOtherApp") == "co.sstools.Batty.broker.plist")
        #expect(BrokerAgentController.resolvedPlistName(bundleIdentifier: nil) == "co.sstools.Batty.broker.plist")
    }
}

/// `BrokerAgentController.agentIsEmbedded` gates the Settings row (#0270
/// round-2 review). Both variants embed their own broker as of #0277, so
/// this now only guards a bundle built before that landed, or a
/// hand-stripped one — the UI must detect that and show "Not available in
/// this build" instead of a "Register" button that can only fail.
struct BrokerAgentIsEmbeddedTests {
    private func makeTempBundleRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "BrokerAgentIsEmbeddedTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func trueWhenPlistPresent() throws {
        let root = makeTempBundleRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let agentsDir = root.appending(path: "Contents/Library/LaunchAgents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        let plistName = "co.sstools.Batty.broker.plist"
        try Data().write(to: agentsDir.appending(path: plistName, directoryHint: .notDirectory))

        let isEmbedded = BrokerAgentController.agentIsEmbedded(
            bundleURL: root,
            plistName: plistName,
            fileManager: .default
        )
        #expect(isEmbedded)
    }

    @Test func falseWhenPlistAbsent() {
        let root = makeTempBundleRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let isEmbedded = BrokerAgentController.agentIsEmbedded(
            bundleURL: root,
            plistName: "co.sstools.Batty.broker.plist",
            fileManager: .default
        )
        #expect(!isEmbedded)
    }
}
