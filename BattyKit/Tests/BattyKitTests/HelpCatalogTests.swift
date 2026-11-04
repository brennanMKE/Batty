// HelpCatalogTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct HelpCatalogTests {
    private static func helpFolder() -> URL {
        // #filePath: .../BattyKit/Tests/BattyKitTests/HelpCatalogTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // -> BattyKitTests/
            .deletingLastPathComponent() // -> Tests/
            .deletingLastPathComponent() // -> BattyKit/
            .appending(path: "Sources/BattyKit/Help", directoryHint: .isDirectory)
    }

    @Test func everySectionHasItsFileAndLicensesStayLast() {
        for section in HelpCatalog.sections {
            let file = Self.helpFolder().appending(path: "\(section.resourceName).md", directoryHint: .notDirectory)
            #expect(FileManager.default.fileExists(atPath: file.path), "\(section.resourceName)")
        }
        #expect(HelpCatalog.sections.last?.id == "09-third-party-licenses")
        #expect(HelpCatalog.sections.contains { $0.id == "11-backgrounds" })
    }
}
