// ICloudDriveImageFolderTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Temporary folders only: nothing here names the user's iCloud Drive.
struct ICloudDriveImageFolderTests {
    private let base = FileManager.default.temporaryDirectory.appendingPathComponent("batty-cloud-\(UUID().uuidString)", isDirectory: true)
    private let digest = String(repeating: "c", count: 64)

    private var folder: ICloudDriveImageFolder { ICloudDriveImageFolder(cloudDrive: base, variantFolderName: "Batty Beta") }
    private var shared: URL { base.appendingPathComponent("Batty Beta/Project Backgrounds", isDirectory: true) }

    private func cleanUp() { try? FileManager.default.removeItem(at: base) }

    private func source(_ text: String = "bytes") throws -> URL {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("source-\(UUID().uuidString)")
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test(arguments: ["../../etc/passwd", "a/b", "short", String(repeating: "C", count: 64)])
    func rejectsAPathShapedDigest(bad: String) async throws {
        defer { cleanUp() }
        let source = try source()
        await #expect(throws: SharedImageTransportError.invalidDigest) { _ = try await folder.state(digest: bad) }
        await #expect(throws: SharedImageTransportError.invalidDigest) { _ = try await folder.read(digest: bad) }
        await #expect(throws: SharedImageTransportError.invalidDigest) { try await folder.write(from: source, digest: bad) }
        await #expect(throws: SharedImageTransportError.invalidDigest) { try await folder.delete(digest: bad) }
        await #expect(throws: SharedImageTransportError.invalidDigest) { try await folder.requestDownload(digest: bad) }
    }

    @Test func writeArrivesWhole() async throws {
        defer { cleanUp() }
        let folder = folder
        #expect(try await folder.state(digest: digest) == .absent)
        try await folder.write(from: try source("first"), digest: digest)
        #expect(try await folder.state(digest: digest) == .local)
        #expect(try await folder.read(digest: digest) == Data("first".utf8))
        try await folder.write(from: try source("second"), digest: digest)
        #expect(try await folder.read(digest: digest) == Data("second".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: shared.path) == [digest + ".png"])
    }

    @Test func readRefusesAnOversizedFile() async throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let file = shared.appendingPathComponent(digest + ".png")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(ICloudDriveImageFolder.maxFileBytes + 1))
        try handle.close()
        await #expect(throws: SharedImageTransportError.tooLarge) { _ = try await folder.read(digest: digest) }
    }

    @Test func aMissingRootReportsOff() async {
        #expect(await folder.availability() == .off)
    }

    @Test func aPlainFolderIsNotReportedAvailable() async throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        #expect(await folder.availability() == .off)
    }

    @Test func listIgnoresOtherNames() async throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        for name in [digest + ".png", "notes.png", digest + ".txt", String(repeating: "C", count: 64) + ".png"] {
            try Data().write(to: shared.appendingPathComponent(name))
        }
        #expect(try await folder.listDigests() == [digest])
    }

    @Test func aMissingFolderListsNothing() async throws {
        #expect(try await folder.listDigests().isEmpty)
    }
}
