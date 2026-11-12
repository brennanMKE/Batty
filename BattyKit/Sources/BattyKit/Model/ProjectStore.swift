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
    /// `projects.json` exists but this store has never read it, so a write
    /// could replace Projects it knows nothing about.
    case fileUnreadable(path: String)
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

    /// What the store last learned about `projects.json`. `loaded` means the
    /// bytes were read, even if they then failed to decode
    /// (`unreadableOriginal` covers that case). A store that wrote the file is
    /// loaded too, with no read behind it.
    private enum FileState { case loaded, absent, readFailed }

    public private(set) var projects: [Project]
    /// Why the last attempt to share failed, until a publish succeeds.
    public private(set) var syncError: String?

    private let fileURL: URL?
    private var fileState: FileState
    @ObservationIgnored private let fileManager: FileManager
    /// The bytes of a file that could not be fully loaded. Copied to
    /// `projects.json.bak` before the first save overwrites it.
    @ObservationIgnored private var unreadableOriginal: Data?
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private let readFile: @MainActor (URL) throws -> Data
    @ObservationIgnored private let backend: (any ProjectSyncBackend)?
    @ObservationIgnored private let home: String
    /// Runs while a backend is present; ends when its `changes` stream does.
    @ObservationIgnored private(set) var syncTask: Task<Void, Never>?
    /// With false, records, merges and `projects.json` are what they were
    /// before images synced (`docs/feature-flags.md`).
    @ObservationIgnored let sharedImagesEnabled: Bool
    /// After a commit that may change a Shared Project's image. True for a
    /// user's save or share, false for a merge, which must not prompt.
    @ObservationIgnored var onSharedImagesChanged: (@MainActor (_ userInitiated: Bool) -> Void)?

    public init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        clock: @escaping @MainActor () -> Date = { Date() },
        backend: (any ProjectSyncBackend)? = nil,
        home: String = NSHomeDirectory(),
        readFile: @escaping @MainActor (URL) throws -> Data = { try Data(contentsOf: $0) },
        sharedImagesEnabled: Bool = false
    ) {
        self.sharedImagesEnabled = sharedImagesEnabled
        self.fileManager = fileManager
        self.clock = clock
        self.backend = backend
        self.home = home
        self.readFile = readFile
        let resolved = fileURL ?? (try? Self.canonicalFileURL(fileManager: fileManager))
        self.fileURL = resolved
        let loaded = Self.load(fileURL: resolved, readFile: readFile, isRetry: false)
        self.projects = loaded.projects
        self.unreadableOriginal = loaded.unreadableOriginal
        self.fileState = loaded.state
        if let backend {
            backend.onSyncError = { [weak self] error in
                self?.syncError = error.localizedDescription
            }
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

    /// The path of a `projects.json` this store could not read. While set the
    /// list is empty and every write is refused.
    public var unreadableFilePath: String? {
        fileState == .readFailed ? fileURL?.path : nil
    }

    /// Reads the file again if the last read didn't load it, so Projects return
    /// without a relaunch once it can be read. A loaded store does nothing.
    public func retryLoadIfNeeded() {
        reconcileWithFile()
    }

    /// Whether a Project this list doesn't show may still exist: in a file this
    /// store hasn't read, dropped from a file that didn't fully load, or kept
    /// in `projects.json.bak`.
    var mayReferenceUnlistedImages: Bool {
        if fileState == .readFailed || unreadableOriginal != nil { return true }
        guard let fileURL else { return false }
        let backup = fileURL.deletingLastPathComponent().appendingPathComponent(Self.backupFileName)
        return fileManager.fileExists(atPath: backup.path)
    }

    /// The image paths `projects.json` names now, which another running copy may
    /// have saved since this list was read. Nil unless the whole file can be
    /// trusted: it is absent, can't be read or decoded, drops a Project, or has
    /// a newer version.
    func imagePathsInFile() -> Set<String>? {
        guard let fileURL,
              let data = try? readFile(fileURL),
              let file = try? Self.decodeFile(data),
              file.dropped == 0, file.newerVersion == nil
        else { return nil }
        return Set(file.projects.flatMap(\.allBackgroundImagePaths))
    }

    /// The digests `projects.json`'s `sharedImage` values name, which a Project
    /// waiting for its image has no path for. Nil on the same terms as
    /// `imagePathsInFile()`.
    func sharedImageDigestsInFile() -> Set<String>? {
        guard let fileURL,
              let data = try? readFile(fileURL),
              let file = try? Self.decodeFile(data),
              file.dropped == 0, file.newerVersion == nil
        else { return nil }
        return Set(file.projects.compactMap { $0.sharedImage?.digest }).union(file.projects.flatMap(\.tabCustomDigests))
    }

    /// Every digest some Project may still need: the backend's records, this
    /// list and `projects.json`. Nil unless all of them can be trusted, because
    /// the sweep deletes what this leaves out and another Mac may need it.
    func namedSharedImageDigestsIfTrusted() -> Set<String>? {
        guard let backend, backend.snapshotIsAuthoritative, !mayReferenceUnlistedImages else { return nil }
        let snapshot = backend.snapshot()
        guard !backend.snapshotSkippedEntries, imagePathsInFile() != nil, let inFile = sharedImageDigestsInFile() else { return nil }
        var named = inFile.union(projects.compactMap { $0.sharedImage?.digest }).union(projects.flatMap(\.tabCustomDigests))
        for entry in snapshot.values {
            guard case .record(let record) = entry else { continue }
            if case .named(let digest, _)? = record.background?.image {
                named.insert(digest)
            }
            for tab in record.layout.backgroundEntries {
                if let digest = tab.image?.digest { named.insert(digest) }
            }
        }
        return named
    }

    /// `imagePathsInFile()` can't tell an absent file from an unreadable one.
    var fileIsAbsent: Bool {
        guard let fileURL else { return true }
        return !fileManager.fileExists(atPath: fileURL.path)
    }

    /// Whether `projects.json` names this image for a Project whose entry in
    /// this list doesn't: another running copy saved it since this list was read.
    func fileNamesImageTheListDoesNot(digest: String) -> Bool {
        guard let fileURL, let data = try? readFile(fileURL), let file = try? Self.decodeFile(data) else { return false }
        func names(_ project: Project?) -> Bool {
            project?.allBackgroundImagePaths.contains { TerminalBackgroundImageImporter.digest(ofPath: $0) == digest } ?? false
        }
        return file.projects.contains { names($0) && !names(project(id: $0.id)) }
    }

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
        try requireReadableFile()
        var project = project
        project.name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.name.isEmpty else { throw ProjectStoreError.emptyName }
        let key = Self.nameKey(project.name)
        if projects.contains(where: { $0.id != project.id && Self.nameKey($0.name) == key }) {
            throw ProjectStoreError.duplicateName(project.name)
        }
        project.modifiedAt = clock()
        if sharedImagesEnabled {
            project.sharedImage = project.isShared
                ? ProjectSharedImage.forSave(draft: project, stored: self.project(id: project.id))
                : nil
        }
        var updated = projects
        let wasShared: Bool
        if let index = updated.firstIndex(where: { $0.id == project.id }) {
            wasShared = updated[index].isShared
            updated[index] = project
        } else {
            wasShared = false
            updated.append(project)
        }
        if project.isShared { try publish(project) }
        try commit(updated)
        if !project.isShared, wasShared {
            backend?.withdraw(id: project.id)
        }
        if project.isShared || wasShared { onSharedImagesChanged?(true) }
    }

    /// Runs before the local commit, so a refused share changes nothing.
    private func publish(_ project: Project) throws {
        guard let backend else { return }
        do {
            try backend.publish(project.syncRecord(home: home, carriesSharedImage: sharedImagesEnabled))
            syncError = nil
        } catch {
            syncError = error.localizedDescription
            throw error
        }
    }

    public func delete(id: UUID) throws {
        try requireReadableFile()
        guard let existing = project(id: id) else { throw ProjectStoreError.unknownProject(id) }
        try commit(projects.filter { $0.id != id })
        if existing.isShared { backend?.tombstone(id: id, deletedAt: clock()) }
    }

    /// Flips the flag and stamps `modifiedAt`, since sharing changes the
    /// definition's membership. While the file on disk could not be fully
    /// loaded, only memory is updated, as for `recordOpen`.
    public func setShared(id: UUID, _ shared: Bool) throws {
        try requireReadableFile()
        guard let index = projects.firstIndex(where: { $0.id == id }) else { throw ProjectStoreError.unknownProject(id) }
        var updated = projects
        let wasShared = updated[index].isShared
        updated[index].isShared = shared
        updated[index].modifiedAt = clock()
        if sharedImagesEnabled {
            if !shared {
                updated[index].sharedImage = nil
            } else if !wasShared || updated[index].sharedImage == nil {
                updated[index].sharedImage = updated[index].background?.imagePath.flatMap(ProjectSharedImage.named(fromPath:))
            }
        }
        if shared { try publish(updated[index]) }
        if unreadableOriginal != nil {
            projects = updated
            logger.notice("setShared: projects file not fully loaded; keeping the flag in memory only")
        } else {
            try commit(updated)
        }
        if !shared, wasShared {
            backend?.withdraw(id: id)
        }
        onSharedImagesChanged?(true)
    }

    /// Applies the backend's entries to the list. This is the one write to
    /// `projects.json` that is not a direct user action. It runs on a backend
    /// change, and when the store first reads a file it couldn't read or find
    /// before. A file that could not be read or fully loaded is left alone.
    func mergeRemote() {
        guard let backend, backend.isAvailable else { return }
        reconcileWithFile()
        guard fileState != .readFailed else {
            logger.notice("mergeRemote: projects file can't be read; skipping")
            return
        }
        guard unreadableOriginal == nil else {
            logger.notice("mergeRemote: projects file not fully loaded; skipping")
            return
        }
        let merged = ProjectSyncMerge.apply(
            remote: backend.snapshot(), to: projects, home: home, now: clock(),
            withdrawAbsent: backend.snapshotIsAuthoritative,
            honorsSharedImages: sharedImagesEnabled)
        guard merged != projects else { return }
        do {
            try commit(merged)
            onSharedImagesChanged?(false)
        } catch {
            logger.error("mergeRemote: save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Puts `ids` first in the given order; Projects not listed keep their
    /// relative order after them. Unknown ids are ignored.
    public func reorder(_ ids: [UUID]) throws {
        try requireReadableFile()
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
        try requireReadableFile()
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
        try requireReadableFile()
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

    /// Clears the path of every Project naming this image and keeps its fit,
    /// position and opacities. Device state, like `recordApproval`: the path
    /// never syncs, so this does not stamp `modifiedAt` or reach the backend.
    /// A `sharedImage` naming it goes too, so the image isn't downloaded again.
    func clearBackgroundImage(digest: String) throws {
        try requireReadableFile()
        var updated = projects
        var changed = false
        for index in updated.indices {
            if updated[index].sharedImage?.digest == digest {
                updated[index].sharedImage = nil
                changed = true
            }
            func names(_ settings: TerminalBackgroundSettings) -> Bool {
                settings.imagePath.flatMap(TerminalBackgroundImageImporter.digest(ofPath:)) == digest
            }
            if updated[index].layout.backgroundEntries.contains(where: { $0.background.map(names) ?? false }) {
                updated[index].layout = updated[index].layout.mappingTabBackgrounds { names($0) ? $0.withImagePath(nil) : $0 }
                changed = true
            }
            guard let background = updated[index].background, names(background) else { continue }
            updated[index].background = background.withImagePath(nil)
            changed = true
        }
        guard changed else { return }
        if unreadableOriginal != nil {
            projects = updated
            logger.notice("clearBackgroundImage: projects file not fully loaded; keeping the change in memory only")
            return
        }
        try commit(updated)
    }

    /// An image from another Mac has arrived. Device state, like
    /// `recordApproval`: no stamp and no publish. Does nothing, returning false,
    /// unless the Project still names this digest, since the user may have
    /// picked another image during the download.
    @discardableResult
    func setResolvedSharedImage(id: UUID, digest: String, path: String) throws -> Bool {
        try requireReadableFile()
        guard let index = projects.firstIndex(where: { $0.id == id }),
              projects[index].sharedImage?.digest == digest,
              let background = projects[index].background
        else { return false }
        var updated = projects
        updated[index].background = background.withImagePath(path)
        if unreadableOriginal != nil {
            projects = updated
            logger.notice("setResolvedSharedImage: projects file not fully loaded; keeping the path in memory only")
            return true
        }
        try commit(updated)
        return true
    }

    /// A Tab's image has been found or has arrived on this Mac. Device state:
    /// no stamp and no publish. Sets the path on every Tab of the Project that
    /// names `identity`; false when none does.
    @discardableResult
    func setResolvedTabImage(projectID: UUID, identity: ProjectTabImage, path: String) throws -> Bool {
        try requireReadableFile()
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return false }
        let project = projects[index]
        guard project.layout.backgroundEntries.contains(where: { $0.image == identity && $0.background != nil && $0.background?.imagePath != path }) else {
            return false
        }
        var updated = projects
        updated[index].layout = project.layout.mappingBackgroundEntries { entry in
            guard entry.image == identity, let background = entry.background else { return entry }
            var entry = entry
            entry.background = background.withImagePath(path)
            return entry
        }
        try commitDeviceState(updated, "setResolvedTabImage")
        return true
    }

    /// Paths the downloaded cache evicted. Device state, like
    /// `setResolvedTabImage`: the identities stay, so a later open fetches again.
    func clearTabImagePaths(_ paths: Set<String>) throws {
        guard !paths.isEmpty else { return }
        try requireReadableFile()
        var updated = projects
        var changed = false
        for index in updated.indices where updated[index].tabBackgroundImagePaths.contains(where: paths.contains) {
            updated[index].layout = updated[index].layout.mappingTabBackgrounds { settings in
                settings.imagePath.map(paths.contains) == true ? settings.withImagePath(nil) : settings
            }
            changed = true
        }
        guard changed else { return }
        try commitDeviceState(updated, "clearTabImagePaths")
    }

    private func commitDeviceState(_ updated: [Project], _ caller: String) throws {
        if unreadableOriginal != nil {
            projects = updated
            logger.notice("\(caller, privacy: .public): projects file not fully loaded; keeping the change in memory only")
            return
        }
        try commit(updated)
    }

    private func commit(_ updated: [Project]) throws {
        let previous = projects
        projects = updated
        do {
            try writeFile()
        } catch {
            projects = previous
            logger.error("projects save failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    public func save() throws {
        try requireReadableFile()
        try writeFile()
    }

    /// Runs first in every mutator, because each builds its new list from
    /// `projects`, which a heal replaces.
    private func requireReadableFile() throws {
        reconcileWithFile()
        if fileState == .readFailed, let fileURL {
            throw ProjectStoreError.fileUnreadable(path: fileURL.path)
        }
    }

    /// Reads the file again unless it is loaded. `projects` is empty outside
    /// the loaded state, since a commit there either moves to loaded or rolls
    /// back, so a heal can replace the list outright. It also runs a merge,
    /// because a backend change skipped while unread won't be sent again.
    private func reconcileWithFile() {
        guard fileState != .loaded else { return }
        let result = Self.load(fileURL: fileURL, readFile: readFile, isRetry: true)
        setFileState(result.state)
        guard result.state == .loaded else { return }
        projects = result.projects
        unreadableOriginal = result.unreadableOriginal
        mergeRemote()
    }

    /// `@Observable` notifies on equal writes, and this runs when a view appears.
    private func setFileState(_ state: FileState) {
        if fileState != state { fileState = state }
    }

    /// Encodes first, so an encode failure never touches the file.
    private func writeFile() throws {
        guard let fileURL else { throw ProjectStoreError.noFileURL }
        guard fileState != .readFailed else { throw ProjectStoreError.fileUnreadable(path: fileURL.path) }
        let data = try ProjectsFile.encoder.encode(ProjectsFile(projects: projects))
        try ensureContainerExists(for: fileURL)
        if let original = unreadableOriginal {
            let backup = fileURL.deletingLastPathComponent().appendingPathComponent(Self.backupFileName)
            try original.write(to: backup, options: [.atomic])
            logger.error("preserved unreadable projects file at \(backup.path, privacy: .public)")
            unreadableOriginal = nil
        }
        try writeAtomically(data: data, to: fileURL)
        setFileState(.loaded)
        logger.debug("projects saved (\(self.projects.count) projects, \(data.count) bytes)")
    }

    private static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The read alone tells a missing file from an unreadable one: `fileExists`
    /// is also false under a parent folder that can't be searched.
    private static func load(
        fileURL: URL?,
        readFile: @MainActor (URL) throws -> Data,
        isRetry: Bool
    ) -> (projects: [Project], unreadableOriginal: Data?, state: FileState) {
        guard let fileURL else { return ([], nil, .absent) }
        let data: Data
        do {
            data = try readFile(fileURL)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError {
                return ([], nil, .absent)
            }
            if isRetry {
                logger.debug("projects read still failing (\(error.localizedDescription, privacy: .public))")
            } else {
                logger.error("projects read failed (\(error.localizedDescription, privacy: .public)); showing none and refusing writes until it can be read")
            }
            return ([], nil, .readFailed)
        }
        do {
            let file = try decodeFile(data)
            if let newerVersion = file.newerVersion {
                logger.error("projects file version \(newerVersion) is newer than \(ProjectsFile.currentVersion); keeping the original until the next save")
            }
            logger.debug("projects loaded (\(file.projects.count) projects, \(file.dropped) dropped)")
            return (file.projects, file.dropped > 0 || file.newerVersion != nil ? data : nil, .loaded)
        } catch {
            logger.error("projects file unreadable (\(String(describing: error), privacy: .public)); starting empty and keeping the original until the next save")
            return ([], data, .loaded)
        }
    }

    private static func decodeFile(_ data: Data) throws -> (projects: [Project], dropped: Int, newerVersion: Int?) {
        let file = try ProjectsFile.decoder.decode(LossyProjectsFile.self, from: data)
        var seen = Set<UUID>()
        var names = Set<String>()
        var projects: [Project] = []
        var dropped = 0
        for element in file.elements {
            guard let project = element.project,
                  seen.insert(project.id).inserted,
                  names.insert(nameKey(project.name)).inserted,
                  !nameKey(project.name).isEmpty else {
                dropped += 1
                continue
            }
            projects.append(project)
        }
        let version = file.version ?? 0
        return (projects, dropped, version > ProjectsFile.currentVersion ? version : nil)
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
