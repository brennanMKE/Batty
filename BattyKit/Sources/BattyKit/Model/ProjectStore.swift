// ProjectStore.swift

import BattyXPCCore
import Foundation
import Observation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "ProjectStore")

public enum ProjectStoreError: Error, Sendable, Equatable {
    case emptyName
    case duplicateName(String)
    case applicationSupportUnavailable
    case noFileURL
    case unknownProject(UUID)
}

struct ProjectsFile: Encodable {
    static let currentVersion = 1
    var version: Int = ProjectsFile.currentVersion
    var projects: [Project]

    nonisolated private static func makeFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(makeFormatter(fractional: true).string(from: date))
        }
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            guard let date = makeFormatter(fractional: true).date(from: string)
                    ?? makeFormatter(fractional: false).date(from: string) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid ISO 8601 date: \(string)"))
            }
            return date
        }
        return d
    }()
}

/// Decodes one element without ever throwing, so a bad Project cannot drop
/// its neighbours.
private struct LossyProject: Decodable {
    let project: Project?
    init(from decoder: Decoder) throws {
        do {
            project = try Project(from: decoder)
        } catch {
            logger.error("dropping undecodable project: \(String(describing: error), privacy: .public)")
            project = nil
        }
    }
}

private struct LossyProjectsFile: Decodable {
    let version: Int?
    let elements: [LossyProject]
    enum CodingKeys: String, CodingKey { case version, projects }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version)
        elements = try c.decode([LossyProject].self, forKey: .projects)
    }
}

@MainActor
@Observable
public final class ProjectStore {
    public static let fileName = "projects.json"
    public static let backupFileName = "projects.json.bak"

    public private(set) var projects: [Project]

    private let fileURL: URL?
    @ObservationIgnored private let fileManager: FileManager
    /// The bytes of a file that could not be fully loaded. Copied to
    /// `projects.json.bak` before the first save overwrites it.
    @ObservationIgnored private var unreadableOriginal: Data?
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private let backend: (any ProjectSyncBackend)?
    @ObservationIgnored private let home: String
    /// Runs while a backend is present; ends when its `changes` stream does.
    @ObservationIgnored private(set) var syncTask: Task<Void, Never>?

    public init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        clock: @escaping @MainActor () -> Date = { Date() },
        backend: (any ProjectSyncBackend)? = nil,
        home: String = NSHomeDirectory()
    ) {
        self.fileManager = fileManager
        self.clock = clock
        self.backend = backend
        self.home = home
        let resolved = fileURL ?? (try? Self.canonicalFileURL(fileManager: fileManager))
        self.fileURL = resolved
        let loaded = Self.load(fileURL: resolved, fileManager: fileManager)
        self.projects = loaded.projects
        self.unreadableOriginal = loaded.unreadableOriginal
        if let backend {
            let changes = backend.changes
            syncTask = Task { [weak self] in
                for await _ in changes {
                    guard let self else { return }
                    self.mergeRemote()
                }
            }
        }
    }

    public static func canonicalFileURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) throws -> URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ProjectStoreError.applicationSupportUnavailable
        }
        return appSupport
            .appendingPathComponent(SessionNameCache.resolvedDirectoryName(bundleIdentifier: bundleIdentifier), isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public var url: URL? { fileURL }

    public func project(id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

    /// Case-insensitive exact match on the trimmed name.
    public func project(named name: String) -> Project? {
        let key = Self.nameKey(name)
        return projects.first { Self.nameKey($0.name) == key }
    }

    /// Replaces the Project with the same id in place, or appends it. Throws
    /// `emptyName` / `duplicateName` (names are unique case-insensitively,
    /// since the CLI opens by name) without changing anything. A failed write
    /// rolls the in-memory list back and rethrows.
    public func upsert(_ project: Project) throws {
        var project = project
        project.name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.name.isEmpty else { throw ProjectStoreError.emptyName }
        let key = Self.nameKey(project.name)
        if projects.contains(where: { $0.id != project.id && Self.nameKey($0.name) == key }) {
            throw ProjectStoreError.duplicateName(project.name)
        }
        project.modifiedAt = clock()
        var updated = projects
        let wasShared: Bool
        if let index = updated.firstIndex(where: { $0.id == project.id }) {
            wasShared = updated[index].isShared
            updated[index] = project
        } else {
            wasShared = false
            updated.append(project)
        }
        try commit(updated)
        if project.isShared {
            backend?.publish(project.syncRecord(home: home))
        } else if wasShared {
            backend?.withdraw(id: project.id)
        }
    }

    public func delete(id: UUID) throws {
        guard let existing = project(id: id) else { throw ProjectStoreError.unknownProject(id) }
        try commit(projects.filter { $0.id != id })
        if existing.isShared { backend?.tombstone(id: id, deletedAt: clock()) }
    }

    /// Flips the flag and stamps `modifiedAt`, since sharing changes the
    /// definition's membership. While the file on disk could not be fully
    /// loaded, only memory is updated, as for `recordOpen`.
    public func setShared(id: UUID, _ shared: Bool) throws {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { throw ProjectStoreError.unknownProject(id) }
        var updated = projects
        let wasShared = updated[index].isShared
        updated[index].isShared = shared
        updated[index].modifiedAt = clock()
        if unreadableOriginal != nil {
            projects = updated
            logger.notice("setShared: projects file not fully loaded; keeping the flag in memory only")
        } else {
            try commit(updated)
        }
        if shared {
            backend?.publish(updated[index].syncRecord(home: home))
        } else if wasShared {
            backend?.withdraw(id: id)
        }
    }

    /// Applies the backend's entries to the list. This is the one write to
    /// `projects.json` that is not a direct user action, and it runs only on
    /// a backend change. A file that could not be fully loaded is left alone.
    func mergeRemote() {
        guard let backend, backend.isAvailable else { return }
        guard unreadableOriginal == nil else {
            logger.notice("mergeRemote: projects file not fully loaded; skipping")
            return
        }
        let merged = ProjectSyncMerge.apply(remote: backend.snapshot(), to: projects, home: home, now: clock())
        guard merged != projects else { return }
        do {
            try commit(merged)
        } catch {
            logger.error("mergeRemote: save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Puts `ids` first in the given order; Projects not listed keep their
    /// relative order after them. Unknown ids are ignored.
    public func reorder(_ ids: [UUID]) throws {
        var remaining = projects
        var ordered: [Project] = []
        for id in ids {
            if let index = remaining.firstIndex(where: { $0.id == id }) {
                ordered.append(remaining.remove(at: index))
            }
        }
        try commit(ordered + remaining)
    }

    /// Sets `lastOpenedAt` on the Project and saves. A failed write rolls the
    /// in-memory list back and rethrows. While the file on disk could not be
    /// fully loaded (a dropped Project or a newer version), only memory is
    /// updated: opening a Project must not rewrite a file the user has not
    /// explicitly saved.
    public func recordOpen(id: UUID, at date: Date) throws {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { throw ProjectStoreError.unknownProject(id) }
        var updated = projects
        updated[index].lastOpenedAt = date
        if unreadableOriginal != nil {
            projects = updated
            logger.notice("recordOpen: projects file not fully loaded; keeping lastOpenedAt in memory only")
            return
        }
        try commit(updated)
    }

    /// Stores the startup-command approval. Device state, like `recordOpen`:
    /// it does not stamp `modifiedAt` or reach the backend, and while the file
    /// on disk could not be fully loaded only memory is updated.
    public func recordApproval(id: UUID, hash: String) throws {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { throw ProjectStoreError.unknownProject(id) }
        var updated = projects
        updated[index].approvedCommandsHash = hash
        if unreadableOriginal != nil {
            projects = updated
            logger.notice("recordApproval: projects file not fully loaded; keeping the approval in memory only")
            return
        }
        try commit(updated)
    }

    private func commit(_ updated: [Project]) throws {
        let previous = projects
        projects = updated
        do {
            try save()
        } catch {
            projects = previous
            logger.error("projects save failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Encodes first, so an encode failure never touches the file.
    public func save() throws {
        guard let fileURL else { throw ProjectStoreError.noFileURL }
        let data = try ProjectsFile.encoder.encode(ProjectsFile(projects: projects))
        try ensureContainerExists(for: fileURL)
        if let original = unreadableOriginal {
            let backup = fileURL.deletingLastPathComponent().appendingPathComponent(Self.backupFileName)
            try original.write(to: backup, options: [.atomic])
            logger.error("preserved unreadable projects file at \(backup.path, privacy: .public)")
            unreadableOriginal = nil
        }
        try writeAtomically(data: data, to: fileURL)
        logger.debug("projects saved (\(self.projects.count) projects, \(data.count) bytes)")
    }

    private static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func load(fileURL: URL?, fileManager: FileManager) -> (projects: [Project], unreadableOriginal: Data?) {
        guard let fileURL, fileManager.fileExists(atPath: fileURL.path) else { return ([], nil) }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            logger.error("projects load failed (\(error.localizedDescription, privacy: .public)); starting empty")
            return ([], nil)
        }
        do {
            let file = try ProjectsFile.decoder.decode(LossyProjectsFile.self, from: data)
            let newer = (file.version ?? 0) > ProjectsFile.currentVersion
            if newer {
                logger.error("projects file version \(file.version ?? 0) is newer than \(ProjectsFile.currentVersion); keeping the original until the next save")
            }
            var seen = Set<UUID>()
            var names = Set<String>()
            var loaded: [Project] = []
            var dropped = 0
            for element in file.elements {
                guard let project = element.project,
                      seen.insert(project.id).inserted,
                      names.insert(nameKey(project.name)).inserted,
                      !nameKey(project.name).isEmpty else {
                    dropped += 1
                    continue
                }
                loaded.append(project)
            }
            logger.debug("projects loaded (\(loaded.count) projects, \(dropped) dropped)")
            return (loaded, dropped > 0 || newer ? data : nil)
        } catch {
            logger.error("projects file unreadable (\(String(describing: error), privacy: .public)); starting empty and keeping the original until the next save")
            return ([], data)
        }
    }

    private func ensureContainerExists(for url: URL) throws {
        let dir = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func writeAtomically(data: Data, to destination: URL) throws {
        let tmp = destination.appendingPathExtension("tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmp)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: tmp)
            } else {
                try fileManager.moveItem(at: tmp, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: tmp)
            throw error
        }
    }
}
