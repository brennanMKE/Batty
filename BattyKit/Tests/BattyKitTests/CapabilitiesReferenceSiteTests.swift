// CapabilitiesReferenceSiteTests.swift

import Foundation
import Testing
import BattyXPCCore
@testable import batty

nonisolated struct CapabilitiesReferenceSiteTests {
    // The flags as they will be in the 1.5.0 Prod build.
    static let releaseFlags = FeatureFlags(sharedProjectImages: true, servers: true)

    private static func cliURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "website/docs/cli", directoryHint: .isDirectory)
    }

    private static func committed() throws -> (Data, CapabilitiesPayload) {
        let data = try Data(contentsOf: cliURL().appending(path: "capabilities.json"))
        return (data, try JSONDecoder().decode(CapabilitiesPayload.self, from: data))
    }

    private static func regenerate(_ version: String) -> String {
        "website/docs/cli is stale: run python3 -I tools/build-cli-reference.py --refresh-json --cli-version \(version)"
    }

    @Test func committedCapabilitiesJSONMatchesTheCLI() throws {
        let (data, payload) = try Self.committed()
        let built = CapabilitiesCommand.buildPayload(flags: Self.releaseFlags)
        let stamped = CapabilitiesPayload(
            cliVersion: payload.cliVersion,
            verbs: built.verbs,
            exitCodes: built.exitCodes,
            jsonSchemaDialect: built.jsonSchemaDialect
        )
        let expected = Data((try CapabilitiesCommand.jsonText(stamped) + "\n").utf8)
        #expect(expected == data, Comment(rawValue: Self.regenerate(payload.cliVersion)))
    }

    @Test func committedCapabilitiesJSONNamesARealVersion() throws {
        let (_, payload) = try Self.committed()
        #expect(payload.cliVersion.wholeMatch(of: /\d+\.\d+\.\d+/) != nil)
    }

    @Test func referencePageListsExactlyTheCommittedVerbs() throws {
        let (_, payload) = try Self.committed()
        let page = try String(contentsOf: Self.cliURL().appending(path: "index.md"), encoding: .utf8)
        let headings = page.split(separator: "\n").compactMap { line -> String? in
            guard let m = line.wholeMatch(of: /### `batty (.+)`/) else { return nil }
            return String(m.1)
        }
        #expect(headings.count == Set(headings).count)
        #expect(Set(headings) == Set(payload.verbs.map(\.name)), Comment(rawValue: Self.regenerate(payload.cliVersion)))
    }
}
