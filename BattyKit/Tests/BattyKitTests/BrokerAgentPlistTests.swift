// BrokerAgentPlistTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Reads the actual shipped LaunchAgent plists off disk and asserts each
/// against its own variant's `ServiceNames` derivation (#0270 round-2
/// review; extended per-variant by #0277).
///
/// Each plist's `Label` is hand-typed XML — it cannot be derived from Swift
/// source the way `ServiceNames.agentLabel(for:)`/`agentPlistName(for:)`
/// derive from `ServiceNames.broker(for:)` (a build-phase-copied plist gets
/// no `$(VAR)` substitution). This is the one piece of the "four-string
/// rule" nothing else in this repo checks, for either variant. If a plist
/// and `ServiceNames` ever drift, launchd silently declines to reserve the
/// Mach service name — no error at install time, no warning at
/// registration, nothing in the log — and this is the only thing standing
/// between that and shipping.
struct BrokerAgentPlistTests {
    private static func plistURL(named filename: String) -> URL {
        // #filePath: .../BattyKit/Tests/BattyKitTests/BrokerAgentPlistTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // -> BattyKitTests/
            .deletingLastPathComponent() // -> Tests/
            .deletingLastPathComponent() // -> BattyKit/
            .deletingLastPathComponent() // -> repo root
            .appending(path: "Configuration/\(filename)", directoryHint: .notDirectory)
    }

    private static func loadPlist(named filename: String) throws -> [String: Any] {
        let data = try Data(contentsOf: plistURL(named: filename))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: Any])
    }

    private static func filename(for variant: ServiceNames.Variant) -> String {
        ServiceNames.agentPlistName(for: variant)
    }

    @Test(arguments: ServiceNames.Variant.allCases)
    func labelMatchesServiceNamesAgentLabel(variant: ServiceNames.Variant) throws {
        let plist = try Self.loadPlist(named: Self.filename(for: variant))
        #expect(plist["Label"] as? String == ServiceNames.agentLabel(for: variant))
    }

    @Test(arguments: ServiceNames.Variant.allCases)
    func machServicesHasExactlyOneKeyMatchingServiceNamesBroker(variant: ServiceNames.Variant) throws {
        let plist = try Self.loadPlist(named: Self.filename(for: variant))
        let machServices = try #require(plist["MachServices"] as? [String: Any])
        #expect(machServices.count == 1)
        #expect(machServices.keys.first == ServiceNames.broker(for: variant))
    }

    @Test(arguments: ServiceNames.Variant.allCases)
    func bundleProgramMatchesServiceNamesAgentBundleProgram(variant: ServiceNames.Variant) throws {
        let plist = try Self.loadPlist(named: Self.filename(for: variant))
        #expect(plist["BundleProgram"] as? String == ServiceNames.agentBundleProgram)
    }

    @Test(arguments: ServiceNames.Variant.allCases)
    func runAtLoadIsAbsent(variant: ServiceNames.Variant) throws {
        // launchd must start the broker on demand, not at login — that's
        // what lets `batty ping` work with the app never launched.
        let plist = try Self.loadPlist(named: Self.filename(for: variant))
        #expect(plist["RunAtLoad"] == nil)
    }

    @Test func prodAndBetaPlistsDoNotShareALabelOrMachServicesKey() throws {
        let prod = try Self.loadPlist(named: Self.filename(for: .prod))
        let beta = try Self.loadPlist(named: Self.filename(for: .beta))
        #expect(prod["Label"] as? String != beta["Label"] as? String)
        let prodMachServices = try #require(prod["MachServices"] as? [String: Any])
        let betaMachServices = try #require(beta["MachServices"] as? [String: Any])
        #expect(prodMachServices.keys.first != betaMachServices.keys.first)
    }
}
