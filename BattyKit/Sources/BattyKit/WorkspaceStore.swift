// WorkspaceStore.swift

import Foundation
import os

enum WorkspaceStoreError: Error, Sendable {
    case applicationSupportUnavailable
}

enum WorkspaceLoadResult: Sendable {
    case loaded(Workspace)
    case missing
    case recovered(default: Workspace, brokenFileURL: URL, underlyingError: String)

    var workspace: Workspace {
        switch self {
        case .loaded(let w): return w
        case .missing: return Workspace.empty()
        case .recovered(let w, _, _): return w
        }
    }
}

@MainActor
final class WorkspaceStore {
    static let defaultDirectoryName = "Batty"
    static let defaultFileName = "workspace.json"

    private let logger = Logger(subsystem: "co.sstools.Batty", category: "WorkspaceStore")
    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = try Self.canonicalFileURL(fileManager: fileManager)
        }
    }

    var url: URL { fileURL }

    static func canonicalFileURL(fileManager: FileManager = .default) throws -> URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw WorkspaceStoreError.applicationSupportUnavailable
        }
        let dir = appSupport.appendingPathComponent(defaultDirectoryName, isDirectory: true)
        return dir.appendingPathComponent(defaultFileName)
    }

    func save(_ workspace: Workspace) throws {
        try ensureContainerExists()
        let data = try Workspace.prettyEncoder.encode(workspace)
        try writeAtomically(data: data, to: fileURL)
        logger.debug("workspace saved (\(data.count) bytes) to \(self.fileURL.path, privacy: .public)")
    }

    func load() -> WorkspaceLoadResult {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            logger.info("workspace file missing at \(self.fileURL.path, privacy: .public); using empty default")
            return .missing
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let workspace = try Workspace.decoder.decode(Workspace.self, from: data)
            logger.debug("workspace loaded (\(data.count) bytes) from \(self.fileURL.path, privacy: .public)")
            return .loaded(workspace)
        } catch {
            let brokenURL = renameBrokenFile()
            logger.error("workspace file at \(self.fileURL.path, privacy: .public) failed to parse (\(error.localizedDescription, privacy: .public)); preserved at \(brokenURL?.path ?? "<unknown>", privacy: .public)")
            return .recovered(
                default: Workspace.empty(),
                brokenFileURL: brokenURL ?? fileURL,
                underlyingError: String(describing: error)
            )
        }
    }

    private func renameBrokenFile() -> URL? {
        let timestamp = Int(Date().timeIntervalSince1970)
        let brokenURL = fileURL.appendingPathExtension("broken-\(timestamp)")
        do {
            try fileManager.moveItem(at: fileURL, to: brokenURL)
            return brokenURL
        } catch {
            logger.error("could not rename broken workspace file: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func ensureContainerExists() throws {
        let dir = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func writeAtomically(data: Data, to destination: URL) throws {
        let tmp = destination.appendingPathExtension("tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: [.atomic])
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: tmp)
        } else {
            try fileManager.moveItem(at: tmp, to: destination)
        }
    }
}
