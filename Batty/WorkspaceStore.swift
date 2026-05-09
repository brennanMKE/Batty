// WorkspaceStore.swift

import Foundation
import os

enum WorkspaceStoreError: Error, Sendable {
    case applicationSupportUnavailable
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
