// ThirdPartyLicensesSyncTests.swift

import Foundation
import Testing

/// Asserts the repo-root `THIRD-PARTY-LICENSES.md` (the canonical,
/// hand-maintained legal document, `#0318`) is byte-identical to the copy
/// that actually ships inside the app as a Help topic
/// (`BattyKit/Sources/BattyKit/Help/09-third-party-licenses.md`, wired into
/// `HelpCatalog`). Only the shipped copy carries the MIT attribution
/// obligation this file exists to satisfy — a silent edit to one file and
/// not the other would ship stale or missing notices with no build-time
/// signal. This test is that signal. Same pattern as
/// `BrokerAgentPlistTests` (#0270/#0277): read the real files off disk via
/// `#filePath`, not a fixture copy.
struct ThirdPartyLicensesSyncTests {
    private static func repoRootURL() -> URL {
        // #filePath: .../BattyKit/Tests/BattyKitTests/ThirdPartyLicensesSyncTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // -> BattyKitTests/
            .deletingLastPathComponent() // -> Tests/
            .deletingLastPathComponent() // -> BattyKit/
            .deletingLastPathComponent() // -> repo root
    }

    private static func canonicalURL() -> URL {
        repoRootURL().appending(path: "THIRD-PARTY-LICENSES.md", directoryHint: .notDirectory)
    }

    private static func shippedURL() -> URL {
        repoRootURL().appending(
            path: "BattyKit/Sources/BattyKit/Help/09-third-party-licenses.md",
            directoryHint: .notDirectory
        )
    }

    @Test func shippedHelpCopyIsByteIdenticalToRepoRootCopy() throws {
        let canonical = try Data(contentsOf: Self.canonicalURL())
        let shipped = try Data(contentsOf: Self.shippedURL())
        #expect(canonical == shipped)
    }

    @Test func repoRootCopyIsNonEmpty() throws {
        // Guards against both files going empty together and the equality
        // check above passing vacuously.
        let canonical = try Data(contentsOf: Self.canonicalURL())
        #expect(canonical.count > 1000)
    }
}
