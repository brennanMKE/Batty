// BrokerAgentPlistTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Reads the actual shipped `Configuration/co.sstools.Batty.broker.plist`
/// off disk and asserts it against `ServiceNames` (#0270 round-2 review).
///
/// The plist's `Label` is hand-typed XML — it cannot be derived from Swift
/// source the way `ServiceNames.agentLabel`/`agentPlistName` derive from
/// `ServiceNames.broker` (a build-phase-copied plist gets no `$(VAR)`
/// substitution). It is the one piece of the "four-string rule" nothing
/// else in this repo checks. This test is that check: if the plist and
/// `ServiceNames` ever drift, launchd silently declines to reserve the
/// Mach service name — no error at install time, no warning at
/// registration, nothing in the log — and this is the only thing standing
/// between that and shipping.
struct BrokerAgentPlistTests {
    private static var plistURL: URL {
        // #filePath: .../BattyKit/Tests/BattyKitTests/BrokerAgentPlistTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // -> BattyKitTests/
            .deletingLastPathComponent() // -> Tests/
            .deletingLastPathComponent() // -> BattyKit/
            .deletingLastPathComponent() // -> repo root
            .appending(path: "Configuration/co.sstools.Batty.broker.plist", directoryHint: .notDirectory)
    }

    private static func loadPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: Any])
    }

    @Test func labelMatchesServiceNamesAgentLabel() throws {
        let plist = try Self.loadPlist()
        #expect(plist["Label"] as? String == ServiceNames.agentLabel)
    }

    @Test func machServicesHasExactlyOneKeyMatchingServiceNamesBroker() throws {
        let plist = try Self.loadPlist()
        let machServices = try #require(plist["MachServices"] as? [String: Any])
        #expect(machServices.count == 1)
        #expect(machServices.keys.first == ServiceNames.broker)
    }

    @Test func bundleProgramMatchesServiceNamesAgentBundleProgram() throws {
        let plist = try Self.loadPlist()
        #expect(plist["BundleProgram"] as? String == ServiceNames.agentBundleProgram)
    }

    @Test func runAtLoadIsAbsent() throws {
        // launchd must start the broker on demand, not at login — that's
        // what lets `batty ping` work with the app never launched.
        let plist = try Self.loadPlist()
        #expect(plist["RunAtLoad"] == nil)
    }
}
