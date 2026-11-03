// TerminalBackgroundImageImporterTests.swift

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BattyKit

@MainActor
final class TerminalBackgroundImageImporterTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("batty-importer-tests-\(UUID().uuidString)", isDirectory: true)
    private var sourceFolder: URL { root.appendingPathComponent("source", isDirectory: true) }
    private var parent: URL { root.appendingPathComponent("imported", isDirectory: true) }
    private var directory: URL { parent.appendingPathComponent("111", isDirectory: true) }
    private var appWideDirectory: URL { root.appendingPathComponent("app-wide", isDirectory: true) }

    init() throws {
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
    }

    @MainActor deinit { try? FileManager.default.removeItem(at: root) }

    private func encoded(width: Int = 256, height: Int = 256, type: UTType = .png) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Varied pixels, so the file has real compressed data to damage.
        for x in stride(from: 0, to: width, by: max(width / 64, 1)) {
            for y in stride(from: 0, to: height, by: max(height / 64, 1)) {
                context.setFillColor(red: CGFloat(x % 97) / 97, green: CGFloat(y % 89) / 89, blue: CGFloat((x ^ y) % 83) / 83, alpha: 1)
                context.fill(CGRect(x: x, y: y, width: max(width / 64, 1), height: max(height / 64, 1)))
            }
        }
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let output = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil)
        #expect(CGImageDestinationFinalize(output))
        return data as Data
    }

    private func source(_ data: Data, named name: String = "photo.png") throws -> URL {
        let url = sourceFolder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func importer() -> TerminalBackgroundImageImporter {
        TerminalBackgroundImageImporter(directory: directory, cleanup: .deadProcessFolders, isProcessAlive: { _ in false })
    }

    private func expectCompletePNG(atPath path: String, differingFrom original: Data) throws {
        #expect(path.hasPrefix(directory.path))
        let output = try Data(contentsOf: URL(fileURLWithPath: path))
        let imageSource = try #require(CGImageSourceCreateWithData(output as CFData, nil))
        #expect(CGImageSourceGetType(imageSource) as String? == UTType.png.identifier)
        #expect(CGImageSourceCreateImageAtIndex(imageSource, 0, nil) != nil)
        #expect(output.suffix(8).prefix(4) == Data("IEND".utf8))
        #expect(output != original)
    }

    private func pixelSize(atPath path: String) throws -> (width: Int, height: Int) {
        let url = URL(fileURLWithPath: path)
        let imageSource = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        return (image.width, image.height)
    }

    @Test func importsPNGAsPNG() async throws {
        let original = try encoded()
        let path = try await importer().importImage(from: source(original))
        let imageSource = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        #expect(CGImageSourceGetType(imageSource) as String? == UTType.png.identifier)
        #expect(path.hasPrefix(directory.path))
    }

    @Test func importsJPEGAsPNG() async throws {
        let original = try encoded(type: .jpeg)
        let path = try await importer().importImage(from: source(original, named: "photo.jpg"))
        try expectCompletePNG(atPath: path, differingFrom: original)
        #expect(path.hasSuffix("/photo.png"))
    }

    @Test func reencodesABitFlippedPNG() async throws {
        let original = try encoded()
        var damaged = original
        damaged[damaged.count / 2] ^= 0x01
        let path = try await importer().importImage(from: source(damaged))
        try expectCompletePNG(atPath: path, differingFrom: damaged)
    }

    @Test func reencodesATruncatedPNG() async throws {
        let damaged = try encoded().prefix(upTo: try encoded().count / 2)
        let path = try await importer().importImage(from: source(Data(damaged)))
        try expectCompletePNG(atPath: path, differingFrom: Data(damaged))
    }

    @Test func reencodesATruncatedJPEG() async throws {
        let original = try encoded(type: .jpeg)
        let damaged = Data(original.prefix(original.count / 2))
        let path = try await importer().importImage(from: source(damaged, named: "photo.jpg"))
        try expectCompletePNG(atPath: path, differingFrom: damaged)
    }

    @Test func capsAnOversizedImage() async throws {
        let original = try encoded(width: 20000, height: 10)
        let path = try await importer().importImage(from: source(original))
        let size = try pixelSize(atPath: path)
        #expect(max(size.width, size.height) <= TerminalBackgroundImageImporter.maxPixelSize)
    }

    @Test func leavesASmallImageAtItsOwnSize() async throws {
        let path = try await importer().importImage(from: source(try encoded(width: 320, height: 200)))
        let size = try pixelSize(atPath: path)
        #expect(size.width == 320 && size.height == 200)
    }

    @Test func rejectsAZeroByteFile() async throws {
        let url = try source(Data())
        await #expect(throws: (any Error).self) { try await importer().importImage(from: url) }
    }

    @Test func rejectsRandomBytes() async throws {
        let url = try source(Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }))
        await #expect(throws: (any Error).self) { try await importer().importImage(from: url) }
    }

    @Test func rejectsAMissingFile() async throws {
        let url = sourceFolder.appendingPathComponent("absent.png")
        await #expect(throws: (any Error).self) { try await importer().importImage(from: url) }
    }

    @Test func sameSourceReusesItsFile() async throws {
        let importer = importer()
        let url = try source(try encoded())
        let first = try await importer.importImage(from: url)
        let sentinel = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: first)
        let second = try await importer.importImage(from: url)
        #expect(second == first)
        let attributes = try FileManager.default.attributesOfItem(atPath: second)
        #expect(attributes[.modificationDate] as? Date == sentinel)
    }

    private func plantFile(in folder: URL) throws -> URL {
        let file = folder.appendingPathComponent("old.png")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: file)
        return file
    }

    @Test func folderIsTheDigestOfTheCopy() async throws {
        let path = try await importer().importImage(from: source(try encoded()))
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent == digest)
    }

    @Test func reimportRepairsADamagedCopy() async throws {
        let importer = importer()
        let url = try source(try encoded())
        let first = try await importer.importImage(from: url)
        let intact = try Data(contentsOf: URL(fileURLWithPath: first))
        try Data(intact.prefix(intact.count / 2)).write(to: URL(fileURLWithPath: first))
        #expect(TerminalBackgroundImageImporter.inspect(path: first, directory: directory) == .rejected)
        let second = try await importer.importImage(from: url)
        #expect(second == first)
        #expect(try Data(contentsOf: URL(fileURLWithPath: second)) == intact)
    }

    @Test func firstImportRemovesDeadProcessFolders() async throws {
        let dead = try plantFile(in: parent.appendingPathComponent("222", isDirectory: true))
        _ = try await importer().importImage(from: source(try encoded()))
        #expect(!FileManager.default.fileExists(atPath: dead.path))
    }

    /// Another running copy of the app must keep its images.
    @Test func firstImportKeepsLiveProcessFolders() async throws {
        let live = try plantFile(in: parent.appendingPathComponent("333", isDirectory: true))
        let dead = try plantFile(in: parent.appendingPathComponent("444", isDirectory: true))
        let importer = TerminalBackgroundImageImporter(
            directory: directory,
            cleanup: .deadProcessFolders,
            isProcessAlive: { $0 == 333 }
        )
        _ = try await importer.importImage(from: source(try encoded()))
        #expect(FileManager.default.fileExists(atPath: live.path))
        #expect(!FileManager.default.fileExists(atPath: dead.path))
    }

    @Test func firstImportRemovesLegacyDigestFolders() async throws {
        let legacy = try plantFile(in: parent.appendingPathComponent(String(repeating: "a", count: 64), isDirectory: true))
        _ = try await importer().importImage(from: source(try encoded()))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    private func appWideImporter() -> TerminalBackgroundImageImporter {
        TerminalBackgroundImageImporter(directory: appWideDirectory, cleanup: .allButRetained)
    }

    @Test func firstImportKeepsTheRetainedImage() async throws {
        let retained = try plantFile(in: appWideDirectory.appendingPathComponent("kept", isDirectory: true))
        _ = try await appWideImporter().importImage(from: source(try encoded()), retaining: retained.path)
        #expect(FileManager.default.fileExists(atPath: retained.path))
    }

    @Test func firstImportRemovesOtherUnreferencedImages() async throws {
        let retained = try plantFile(in: appWideDirectory.appendingPathComponent("kept", isDirectory: true))
        let other = try plantFile(in: appWideDirectory.appendingPathComponent("other", isDirectory: true))
        _ = try await appWideImporter().importImage(from: source(try encoded()), retaining: retained.path)
        #expect(!FileManager.default.fileExists(atPath: other.path))
    }

    @Test func laterImportsDoNotSweep() async throws {
        let importer = appWideImporter()
        _ = try await importer.importImage(from: source(try encoded(width: 64, height: 64), named: "a.png"))
        let later = try plantFile(in: appWideDirectory.appendingPathComponent("later", isDirectory: true))
        _ = try await importer.importImage(from: source(try encoded(width: 32, height: 32), named: "b.png"))
        #expect(FileManager.default.fileExists(atPath: later.path))
    }

    @Test func secondImportKeepsTheFirstImportsFile() async throws {
        let importer = importer()
        let first = try await importer.importImage(from: source(try encoded(width: 64, height: 64), named: "a.png"))
        _ = try await importer.importImage(from: source(try encoded(width: 32, height: 32), named: "b.png"))
        #expect(FileManager.default.fileExists(atPath: first))
    }

    @Test func importedPathSurvivesSettingsNormalization() async throws {
        let url = try source(try encoded(), named: "my \"best\u{07}\" photo.png")
        let path = try await importer().importImage(from: url)
        #expect(TerminalBackgroundSettings(imagePath: path).imagePath == path)
        #expect(!path.contains("\""))
    }

    @Test func aLongMultibyteNameStillImports() async throws {
        let url = try source(try encoded(), named: String(repeating: "写", count: 80) + ".png")
        let path = try await importer().importImage(from: url)
        #expect(FileManager.default.fileExists(atPath: path))
    }
}
