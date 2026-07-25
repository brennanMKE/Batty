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

/// `BrokerAgentController.agentIsEmbedded` gates the Settings row (#0270
/// round-2 review): a Beta bundle never embeds the broker plist (Prod-only
/// decision), so the UI must detect that and show "Not available in this
/// build" instead of a "Register" button that can only fail.
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
