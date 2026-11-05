// BackgroundImageLibraryTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct BackgroundImageLibraryTests {
    private let f: ProjectBackgroundFixture
    private var library: BackgroundImageLibrary { f.imageLibrary }

    init() throws { f = try ProjectBackgroundFixture() }

    private func source(width: Int = 64, named name: String = "harbor.png") throws -> URL {
        let url = f.base.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try BackgroundTestImage.encoded(width: width).write(to: url)
        return url
    }

    private func sourceNamed(_ name: String, data: Data) throws -> URL {
        let folder = f.base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func digestCopy(in folder: URL, _ data: Data, named name: String = "photo.png") throws -> String {
        let digestFolder = folder.appendingPathComponent(BackgroundTestImage.digest(of: data), isDirectory: true)
        try FileManager.default.createDirectory(at: digestFolder, withIntermediateDirectories: true)
        let file = digestFolder.appendingPathComponent(name)
        try data.write(to: file)
        return file.path
    }

    @Test func directoryIsBesideTheProjectsFileAndOutsideTerminalBackgrounds() {
        let directory = BackgroundImageLibrary.directory(forProjectsFile: f.projectsFile)
        #expect(directory.deletingLastPathComponent().path == f.projectsFile.deletingLastPathComponent().path)
        #expect(directory.lastPathComponent == "BackgroundImages")
        #expect(!directory.pathComponents.contains("TerminalBackgrounds"))
        #expect(!directory.pathComponents.contains("ProjectBackgrounds"))
    }

    @Test func initTouchesNoFiles() {
        _ = BackgroundImageLibrary(directory: f.libraryFolder, sources: [f.projectFolder])
        #expect(!FileManager.default.fileExists(atPath: f.libraryFolder.path))
    }

    @Test func addStoresAnIntactPngNamedForItsDigest() async throws {
        let entry = try await library.add(from: try source())
        #expect(entry.name.hasSuffix("harbor"))
        #expect(entry.sizeInBytes > 0)
        #expect(TerminalBackgroundImageImporter.inspect(path: entry.path, directory: f.libraryFolder) == .usable)
        #expect(TerminalBackgroundImageImporter.digest(ofPath: entry.path) == entry.digest)
    }

    @Test func addRefusesAnUndecodableFileAndLeavesNothing() async throws {
        let bad = try sourceNamed("bad.png", data: Data("not an image".utf8))
        await #expect(throws: (any Error).self) { try await library.add(from: bad) }
        #expect(await library.scan().isEmpty)
    }

    @Test func addScalesDownToTheImporterLimit() async throws {
        let big = try source(width: TerminalBackgroundImageImporter.maxPixelSize + 1)
        let entry = try await library.add(from: big)
        #expect(TerminalBackgroundImageImporter.isWithinPixelLimit(path: entry.path))
    }

    @Test func addingTheSameImageUnderTwoNamesGivesOneEntry() async throws {
        let data = try BackgroundTestImage.encoded(width: 64)
        let first = try await library.add(from: try sourceNamed("b.png", data: data))
        let second = try await library.add(from: try sourceNamed("a.png", data: data))
        #expect(first.digest == second.digest)
        let entries = await library.scan()
        #expect(entries.count == 1)
        #expect(entries.first?.name == "a")
    }

    @Test func scanPromotesCopiesSoTheyOutliveTheirSourceFolder() async throws {
        let path = try await f.copy(in: f.appWideFolder, width: 64, named: "harbor.png")
        #expect(await library.scan().count == 1)
        try f.removeFolder(of: path)
        let entries = await library.scan()
        #expect(entries.count == 1)
        #expect(entries.first.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @Test func scanShowsOneEntryForADigestInSeveralFolders() async throws {
        let inProject = try await f.copy(in: f.projectFolder, width: 64, named: "one.png")
        let inPane = try await f.copy(in: f.paneFolder, width: 64, named: "two.png")
        #expect(TerminalBackgroundImageImporter.digest(ofPath: inProject) == TerminalBackgroundImageImporter.digest(ofPath: inPane))
        #expect(await library.scan().count == 1)
    }

    @Test func scanSkipsADamagedSourceCopy() async throws {
        let path = try await f.copy(in: f.paneFolder, width: 64)
        try BackgroundTestImage.encoded(width: 80).write(to: URL(fileURLWithPath: path))
        #expect(await library.scan().isEmpty)
    }

    @Test func scanSkipsAnOversizedSourceCopy() async throws {
        let wide = try BackgroundTestImage.encoded(width: TerminalBackgroundImageImporter.maxPixelSize + 1, height: 4)
        _ = try digestCopy(in: f.paneFolder, wide)
        #expect(await library.scan().isEmpty)
    }

    @Test func scanDoesNotReadASiblingProcessFolder() async throws {
        let sibling = f.base.appendingPathComponent("pane-other", isDirectory: true)
        _ = try await f.copy(in: sibling, width: 64)
        #expect(await library.scan().isEmpty)
    }

    @Test func removeDeletesEveryCopyOfTheDigest() async throws {
        let inProject = try await f.copy(in: f.projectFolder, width: 64)
        let inPane = try await f.copy(in: f.paneFolder, width: 64)
        let entry = try #require(await library.scan().first)
        #expect(await library.remove(digest: entry.digest).isEmpty)
        for path in [inProject, inPane, entry.path] {
            #expect(!FileManager.default.fileExists(atPath: path))
        }
    }

    @Test func removeLeavesOtherDigests() async throws {
        let first = try await library.add(from: try source(width: 64))
        let second = try await library.add(from: try source(width: 72))
        _ = await library.remove(digest: first.digest)
        #expect(await library.scan().map(\.digest) == [second.digest])
    }

    @Test func removeRejectsAPathShapedDigest() async throws {
        let entry = try await library.add(from: try source())
        #expect(await library.remove(digest: "..").isEmpty)
        #expect(await library.remove(digest: "../BackgroundImages").isEmpty)
        #expect(FileManager.default.fileExists(atPath: entry.path))
    }

    @Test func removeReportsAFolderItCouldNotDelete() async throws {
        let entry = try await library.add(from: try source())
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.libraryFolder.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.libraryFolder.path) }
        let failed = await library.remove(digest: entry.digest)
        #expect(failed.map(\.lastPathComponent) == [entry.digest])
    }

    @Test func removedImageDoesNotReturnOnTheNextScan() async throws {
        _ = try await f.copy(in: f.projectFolder, width: 64)
        let entry = try #require(await library.scan().first)
        _ = await library.remove(digest: entry.digest)
        #expect(await library.scan().isEmpty)
    }
}
