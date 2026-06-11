// SessionNameToolTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Covers the availability-independent logic behind the #0232 tool-calling
/// suggester: ReadFile-style validation/excerpting and the SetSessionName
/// result box. The Tool conformances themselves are thin wrappers over
/// these helpers and need a live macOS 26 model to exercise.
struct SessionNameToolTests {

    // MARK: - readExcerpt validation

    private func makeTempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-name-tool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func nameOutsideAllowedSetIsRejected() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try "secret".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let result = SessionNameToolSupport.readExcerpt(
            fileName: "notes.txt",
            folderPath: folder.path,
            allowedNames: ["README.md"]
        )
        #expect(result == SessionNameToolSupport.unknownFileMessage)
    }

    @Test func pathTraversalNamesAreRejected() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let allowed: Set<String> = ["README.md", "notes.txt"]

        for name in ["../etc/passwd", "../../etc/passwd", "/etc/passwd", "subdir/notes.txt", "..", "."] {
            let result = SessionNameToolSupport.readExcerpt(
                fileName: name,
                folderPath: folder.path,
                allowedNames: allowed
            )
            #expect(result == SessionNameToolSupport.unknownFileMessage, "\(name) must be rejected")
        }
    }

    @Test func allowedNameReturnsFileContents() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let contents = "# Recipe Manager\n\nA small app for organizing recipes."
        try contents.write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let result = SessionNameToolSupport.readExcerpt(
            fileName: "README.md",
            folderPath: folder.path,
            allowedNames: ["README.md"]
        )
        #expect(result == contents)
    }

    @Test func largeFileIsCappedAtByteLimit() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let big = String(repeating: "abcdefgh", count: 1024)  // 8 KB
        try big.write(to: folder.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)

        let result = SessionNameToolSupport.readExcerpt(
            fileName: "big.txt",
            folderPath: folder.path,
            allowedNames: ["big.txt"]
        )
        #expect(result.utf8.count == SessionNameToolSupport.excerptByteLimit)
        #expect(big.hasPrefix(result))
    }

    @Test func binaryFileReturnsFallbackMessage() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let binary = Data([0xFF, 0xFE, 0x00, 0x80, 0xC3, 0x28, 0xA0, 0xA1])
        try binary.write(to: folder.appendingPathComponent("blob.bin"))

        let result = SessionNameToolSupport.readExcerpt(
            fileName: "blob.bin",
            folderPath: folder.path,
            allowedNames: ["blob.bin"]
        )
        #expect(result == SessionNameToolSupport.unreadableFileMessage)
    }

    @Test func multibyteCharacterSplitAtCapStillDecodes() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // 4095 ASCII bytes followed by a 3-byte scalar straddling the cap.
        var data = Data(repeating: UInt8(ascii: "a"), count: SessionNameToolSupport.excerptByteLimit - 1)
        data.append(contentsOf: "\u{2014}".utf8)
        try data.write(to: folder.appendingPathComponent("notes.txt"))

        let result = SessionNameToolSupport.readExcerpt(
            fileName: "notes.txt",
            folderPath: folder.path,
            allowedNames: ["notes.txt"]
        )
        #expect(result == String(repeating: "a", count: SessionNameToolSupport.excerptByteLimit - 1))
    }

    @Test func directoryEntryReturnsFallbackMessage() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("Sources"),
            withIntermediateDirectories: true
        )

        let result = SessionNameToolSupport.readExcerpt(
            fileName: "Sources",
            folderPath: folder.path,
            allowedNames: ["Sources"]
        )
        #expect(result == SessionNameToolSupport.unreadableFileMessage)
    }

    @Test func emptyFileReturnsFallbackMessage() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        FileManager.default.createFile(atPath: folder.appendingPathComponent("empty.txt").path, contents: nil)

        let result = SessionNameToolSupport.readExcerpt(
            fileName: "empty.txt",
            folderPath: folder.path,
            allowedNames: ["empty.txt"]
        )
        #expect(result == SessionNameToolSupport.unreadableFileMessage)
    }

    // MARK: - SuggestedNameBox semantics (first-call-wins)

    @Test func boxNeverSetReturnsNil() {
        let box = SuggestedNameBox()
        #expect(box.value == nil)
    }

    @Test func boxSetOnceReturnsValue() {
        let box = SuggestedNameBox()
        #expect(box.set("Recipe Manager") == true)
        #expect(box.value == "Recipe Manager")
    }

    @Test func boxFirstCallWins() {
        let box = SuggestedNameBox()
        #expect(box.set("First Name") == true)
        #expect(box.set("Second Name") == false)
        #expect(box.set("Third Name") == false)
        #expect(box.value == "First Name")
    }
}
