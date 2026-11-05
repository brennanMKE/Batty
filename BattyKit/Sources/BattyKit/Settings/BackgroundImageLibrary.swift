// BackgroundImageLibrary.swift

import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "BackgroundImageLibrary")

nonisolated struct BackgroundImageEntry: Sendable, Identifiable, Equatable {
    let digest: String
    let path: String
    let name: String
    let sizeInBytes: Int64
    let addedAt: Date

    var id: String { digest }
}

/// The images the Background Images window shows. Each use keeps its own copy
/// in its own folder, whose cleanup rule can delete it, so a scan copies what
/// the sources hold into a folder only the user's Remove deletes from. Building
/// this touches no files.
actor BackgroundImageLibrary {
    nonisolated let directory: URL
    private let sources: [URL]
    private let importer: TerminalBackgroundImageImporter

    init(directory: URL, sources: [URL]) {
        self.directory = directory
        self.sources = sources
        self.importer = TerminalBackgroundImageImporter(directory: directory, cleanup: .keepAll)
    }

    /// Beside `projects.json`, so each variant and each test store has its own,
    /// and outside the folders whose cleanup rules would delete from it.
    @MainActor static func directory(forProjectsFile file: URL?) -> URL {
        let parent = file?.deletingLastPathComponent()
            ?? TerminalBackgroundImageImporter.appWideDirectory().deletingLastPathComponent()
        return parent.appendingPathComponent("BackgroundImages", isDirectory: true)
    }

    /// Promotes what the sources hold, then lists newest first. A digest already
    /// here is not copied again.
    func scan() -> [BackgroundImageEntry] {
        for source in sources {
            for digest in digestFolders(in: source) where imageFiles(in: directory, digest: digest).isEmpty {
                promote(digest: digest, from: source)
            }
        }
        return digestFolders(in: directory)
            .compactMap(entry(digest:))
            .sorted { ($0.addedAt, $1.digest) > ($1.addedAt, $0.digest) }
    }

    func add(from source: URL) async throws -> BackgroundImageEntry {
        let path = try await importer.importImage(from: source)
        guard let digest = TerminalBackgroundImageImporter.digest(ofPath: path),
              let entry = entry(digest: digest)
        else { throw TerminalBackgroundImageImporter.ImportError.encodingFailed }
        return entry
    }

    /// Deletes the digest's folder here and in every source, so a promoted copy
    /// doesn't come back at the next scan. Returns the folders it couldn't delete.
    func remove(digest: String) -> [URL] {
        guard TerminalBackgroundImageImporter.isDigest(digest) else { return [] }
        let fileManager = FileManager.default
        var failed: [URL] = []
        for root in [directory] + sources {
            let folder = root.appendingPathComponent(digest, isDirectory: true)
            guard fileManager.fileExists(atPath: folder.path) else { continue }
            do {
                try fileManager.removeItem(at: folder)
            } catch {
                logger.error("could not remove a background image: \(error.localizedDescription, privacy: .private)")
                failed.append(folder)
            }
        }
        return failed
    }

    private func promote(digest: String, from source: URL) {
        for file in imageFiles(in: source, digest: digest) {
            let path = source.appendingPathComponent(digest, isDirectory: true).appendingPathComponent(file).path
            guard TerminalBackgroundImageImporter.inspect(path: path, directory: source) == .usable,
                  TerminalBackgroundImageImporter.isWithinPixelLimit(path: path)
            else { continue }
            _ = TerminalBackgroundImageImporter.adopt(path: path, from: [source], into: directory)
            return
        }
    }

    private func entry(digest: String) -> BackgroundImageEntry? {
        guard let file = imageFiles(in: directory, digest: digest).first else { return nil }
        let folder = directory.appendingPathComponent(digest, isDirectory: true)
        let path = folder.appendingPathComponent(file).path
        let fileManager = FileManager.default
        let attributes = (try? fileManager.attributesOfItem(atPath: path)) ?? [:]
        let folderAttributes = (try? fileManager.attributesOfItem(atPath: folder.path)) ?? [:]
        return BackgroundImageEntry(
            digest: digest,
            path: path,
            name: (file as NSString).deletingPathExtension,
            sizeInBytes: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            addedAt: folderAttributes[.creationDate] as? Date ?? .distantPast
        )
    }

    private func digestFolders(in root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter(TerminalBackgroundImageImporter.isDigest)
    }

    private func imageFiles(in root: URL, digest: String) -> [String] {
        let folder = root.appendingPathComponent(digest, isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".png") && !$0.hasPrefix(".") }
            .sorted()
    }
}
