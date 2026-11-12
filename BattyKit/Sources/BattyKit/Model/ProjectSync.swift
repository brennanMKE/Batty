// ProjectSync.swift

import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "ProjectSync")

/// What a record says about its image. `unspecified` is what older Batty writes
/// and keeps this Mac's image, so a remote "Custom, no image" can't clear it;
/// removal has its own encoding for that reason.
public enum ProjectSyncImage: Sendable, Hashable {
    case unspecified
    case named(digest: String, name: String)
    case removed
}

/// A Project's background without its image path, which is device state: a
/// synced path would name a file the other Mac doesn't have, and publishing it
/// would overwrite that Mac's own image. Holds no path however it was built.
public struct ProjectSyncBackground: Codable, Sendable, Hashable {
    public let settings: TerminalBackgroundSettings
    public let image: ProjectSyncImage

    public init(_ settings: TerminalBackgroundSettings, image: ProjectSyncImage = .unspecified) {
        self.settings = settings.withImagePath(nil)
        self.image = image
    }

    private enum ImageKeys: String, CodingKey {
        case imageDigest, imageName, imageRemoved
    }

    /// A bad digest or a wrong type reads as `unspecified`. These keys share the
    /// settings' object, whose decoder ignores them, as older Batty's does.
    public init(from decoder: Decoder) throws {
        let settings = try TerminalBackgroundSettings(from: decoder)
        let c = try decoder.container(keyedBy: ImageKeys.self)
        let image: ProjectSyncImage
        if (try? c.decodeIfPresent(Bool.self, forKey: .imageRemoved)) == true {
            image = .removed
        } else if let digest = (try? c.decodeIfPresent(String.self, forKey: .imageDigest)) ?? nil,
                  TerminalBackgroundImageImporter.isDigest(digest) {
            let name = (try? c.decodeIfPresent(String.self, forKey: .imageName)) ?? nil
            image = .named(digest: digest, name: TerminalBackgroundImageImporter.sanitizedImageName(name ?? "", maxBytes: ProjectSharedImage.maxNameBytes))
        } else {
            image = .unspecified
        }
        self.init(settings, image: image)
    }

    public func encode(to encoder: Encoder) throws {
        try settings.encode(to: encoder)
        var c = encoder.container(keyedBy: ImageKeys.self)
        switch image {
        case .unspecified:
            break
        case .named(let digest, let name):
            try c.encode(digest, forKey: .imageDigest)
            try c.encode(name, forKey: .imageName)
        case .removed:
            try c.encode(true, forKey: .imageRemoved)
        }
    }
}

/// The synced shape of a shared Project: the definition fields and nothing
/// else. It has no `isShared`, `lastOpenedAt` or `approvedCommandsHash`, so
/// device state cannot reach a payload; trust approval is consent given on
/// one Mac and must not carry to another.
public struct ProjectSyncRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// Home-relative (`~/…`) when the root is under the home directory.
    public var rootPath: String
    public var color: SessionColor
    public var symbol: ProjectSymbol
    public var layout: ProjectLayout
    public var runStartupCommandsOnOpen: Bool
    public var modifiedAt: Date?
    /// Optional keys, absent in records from older Batty versions, whose
    /// decoder ignores them and reads the legacy `color` and `symbol`.
    public var customColor: String?
    public var symbolName: String?
    public var background: ProjectSyncBackground?
    public var theme: ThemePair?

    public init(
        id: UUID, name: String, rootPath: String, color: SessionColor, symbol: ProjectSymbol,
        layout: ProjectLayout, runStartupCommandsOnOpen: Bool, modifiedAt: Date?,
        customColor: String? = nil, symbolName: String? = nil,
        background: ProjectSyncBackground? = nil,
        theme: ThemePair? = nil
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.color = color
        self.symbol = symbol
        self.layout = layout
        self.runStartupCommandsOnOpen = runStartupCommandsOnOpen
        self.modifiedAt = modifiedAt
        self.customColor = customColor
        self.symbolName = symbolName
        self.background = background
        self.theme = theme
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, rootPath, color, symbol, layout, runStartupCommandsOnOpen, modifiedAt, customColor, symbolName, background, theme
    }

    /// `background` and `theme` can't fail the record, because the backend's `snapshot()`
    /// skips a record it can't decode. The other fields keep what synthesis did.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        rootPath = try c.decode(String.self, forKey: .rootPath)
        color = try c.decode(SessionColor.self, forKey: .color)
        symbol = try c.decode(ProjectSymbol.self, forKey: .symbol)
        layout = try c.decode(ProjectLayout.self, forKey: .layout)
        runStartupCommandsOnOpen = try c.decode(Bool.self, forKey: .runStartupCommandsOnOpen)
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt)
        customColor = try c.decodeIfPresent(String.self, forKey: .customColor)
        symbolName = try c.decodeIfPresent(String.self, forKey: .symbolName)
        background = (try? c.decodeIfPresent(ProjectSyncBackground.self, forKey: .background)) ?? nil
        theme = ((try? c.decodeIfPresent(ThemePair.self, forKey: .theme)) ?? nil)?.normalized
    }
}

extension ProjectSyncImage {
    fileprivate var projectSharedImage: ProjectSharedImage? {
        switch self {
        case .unspecified: nil
        case .named(let digest, let name): .named(digest: digest, name: name)
        case .removed: .removed
        }
    }
}

extension Project {
    /// Only `sharedImage` can put image keys in the record. Without
    /// `carriesSharedImage` the bytes are what they were before those keys.
    public func syncRecord(home: String, carriesSharedImage: Bool = false) -> ProjectSyncRecord {
        let image: ProjectSyncImage = switch carriesSharedImage ? sharedImage : nil {
        case .named(let digest, let name):
            .named(digest: digest, name: TerminalBackgroundImageImporter.sanitizedImageName(name, maxBytes: ProjectSharedImage.maxNameBytes))
        case .removed: .removed
        case nil: .unspecified
        }
        return ProjectSyncRecord(
            id: id, name: name,
            rootPath: PortablePath.encode(absolute: rootPath, home: home),
            color: color, symbol: symbol, layout: layout,
            runStartupCommandsOnOpen: runStartupCommandsOnOpen,
            modifiedAt: modifiedAt,
            customColor: customColorHex, symbolName: customSymbolName,
            background: background.map { ProjectSyncBackground($0, image: image) },
            theme: theme)
    }

    /// A shared Project with no device state. A root that does not decode to
    /// an absolute path (a `~user/...` form) is anchored at `/`, so the
    /// Project is kept and shows as missing-folder instead of being dropped.
    public init(syncRecord record: ProjectSyncRecord, home: String, honorsSharedImages: Bool = false) {
        let decoded = PortablePath.decode(portable: record.rootPath, home: home)
        self.init(
            id: record.id, name: record.name,
            rootPath: decoded.hasPrefix("/") ? decoded : "/" + decoded,
            color: record.color, symbol: record.symbol, layout: record.layout,
            runStartupCommandsOnOpen: record.runStartupCommandsOnOpen,
            approvedCommandsHash: nil, lastOpenedAt: nil,
            isShared: true, modifiedAt: record.modifiedAt,
            customColorHex: record.customColor, customSymbolName: record.symbolName,
            background: record.background?.settings,
            sharedImage: honorsSharedImages ? record.background?.image.projectSharedImage : nil,
            theme: record.theme)
    }

    fileprivate func replacingDefinition(with record: ProjectSyncRecord, name: String, home: String, honorsSharedImages: Bool) -> Project {
        var merged = Project(syncRecord: record, home: home)
        merged.name = name
        merged.approvedCommandsHash = approvedCommandsHash
        merged.lastOpenedAt = lastOpenedAt
        merged.background = merged.background?.withImagePath(background?.imagePath)
        merged.sharedImage = sharedImage
        guard honorsSharedImages else { return merged }
        switch record.background?.image {
        case nil:
            merged.sharedImage = nil
        case .unspecified:
            break
        case .named(let digest, let name):
            // A different digest keeps the old path: the earlier image shows
            // until the new one arrives.
            merged.sharedImage = .named(digest: digest, name: name)
        case .removed:
            merged.background = merged.background?.withImagePath(nil)
            merged.sharedImage = .removed
        }
        return merged
    }
}

public enum ProjectSyncEntry: Sendable, Equatable {
    case record(ProjectSyncRecord)
    case tombstone(deletedAt: Date)
}

/// Why a backend refused or could not keep a write.
public enum ProjectSyncError: Error, Sendable, Equatable, LocalizedError {
    public enum QuotaReason: Sendable, Equatable {
        case recordTooLarge
        case totalTooLarge
        case tooManyKeys
    }

    case quotaExceeded(reason: QuotaReason)

    public var errorDescription: String? {
        switch self {
        case .quotaExceeded(.recordTooLarge):
            String(localized: "This Project is too large to share through iCloud.", comment: "Shared Projects: a single record exceeds the iCloud key-value size limit")
        case .quotaExceeded(.totalTooLarge):
            String(localized: "Sharing this Project would exceed Batty\u{2019}s iCloud storage limit. Unshare another Project first.", comment: "Shared Projects: the total iCloud key-value quota would be exceeded")
        case .quotaExceeded(.tooManyKeys):
            String(localized: "Batty already shares as many Projects through iCloud as it can. Unshare another Project first.", comment: "Shared Projects: the iCloud key-value key-count limit would be exceeded")
        }
    }
}

/// Where shared Project records go. `LocalOnlyProjectSyncBackend` keeps them
/// in memory; `ICloudKeyValueProjectSyncBackend` writes them to iCloud.
@MainActor
public protocol ProjectSyncBackend: AnyObject {
    var isAvailable: Bool { get }
    func snapshot() -> [UUID: ProjectSyncEntry]
    /// Throws, writing nothing, when the record cannot be kept (a quota).
    func publish(_ record: ProjectSyncRecord) throws
    /// Unshare: the entry is removed and other Macs keep their copy as local.
    func withdraw(id: UUID)
    /// Delete: the entry becomes a tombstone other Macs apply.
    func tombstone(id: UUID, deletedAt: Date)
    var changes: AsyncStream<Void> { get }
    /// Whether an absent entry may be read as "withdrawn elsewhere" (merge
    /// rule 4). False until the backend has seen a server or initial-sync
    /// change, since before that an empty snapshot may only mean the local
    /// cache has not been filled yet.
    var snapshotIsAuthoritative: Bool { get }
    /// Whether the last `snapshot()` skipped an entry it couldn't decode. A
    /// newer version's record may name an image, so nothing can be read from
    /// that image's absence.
    var snapshotSkippedEntries: Bool { get }
    /// Reports a failure that no user action caused, such as the store
    /// rejecting data after the fact. Set by `ProjectStore`.
    var onSyncError: (@MainActor (ProjectSyncError) -> Void)? { get set }
}

/// Keeps entries in memory and never touches disk or the network.
@MainActor
public final class LocalOnlyProjectSyncBackend: ProjectSyncBackend {
    public enum Call: Sendable, Equatable {
        case publish(ProjectSyncRecord)
        case withdraw(UUID)
        case tombstone(UUID, Date)
    }

    public var onSyncError: (@MainActor (ProjectSyncError) -> Void)?
    public var snapshotIsAuthoritative = true
    /// Test seam for a skipped entry.
    public var snapshotSkippedEntries = false
    public private(set) var calls: [Call] = []
    private var entries: [UUID: ProjectSyncEntry] = [:]
    public let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    /// `isAvailable` is false in production use; a test passes true to drive
    /// the store's merge, which ignores an unavailable backend.
    public init(isAvailable: Bool = false) {
        self.isAvailable = isAvailable
        (changes, continuation) = AsyncStream<Void>.makeStream()
    }

    public let isAvailable: Bool

    public func snapshot() -> [UUID: ProjectSyncEntry] { entries }

    public func publish(_ record: ProjectSyncRecord) {
        calls.append(.publish(record))
        entries[record.id] = .record(record)
    }

    public func withdraw(id: UUID) {
        calls.append(.withdraw(id))
        entries[id] = nil
    }

    public func tombstone(id: UUID, deletedAt: Date) {
        calls.append(.tombstone(id, deletedAt))
        entries[id] = .tombstone(deletedAt: deletedAt)
    }

    /// Test seam: stands in for another Mac's write arriving.
    func receive(_ remote: [UUID: ProjectSyncEntry]) {
        entries = remote
        continuation.yield()
    }

    /// Test seam: ends `changes`, so a consumer's loop returns once it has
    /// handled every event yielded before this call.
    func finishChanges() {
        continuation.finish()
    }
}

/// Last writer wins per Project. Pure.
public enum ProjectSyncMerge {
    public static func apply(
        remote: [UUID: ProjectSyncEntry],
        to local: [Project],
        home: String,
        now: Date,
        withdrawAbsent: Bool = true,
        honorsSharedImages: Bool = false
    ) -> [Project] {
        var result: [Project] = []
        var handled = Set<UUID>()

        for project in local {
            guard let entry = remote[project.id] else {
                // Absent from the remote set: withdrawn elsewhere. Kept as local, never deleted.
                var kept = project
                if kept.isShared, withdrawAbsent {
                    kept.isShared = false
                    kept.sharedImage = nil
                }
                result.append(kept)
                continue
            }
            handled.insert(project.id)
            switch entry {
            case .tombstone:
                if project.isShared { continue }
                result.append(project)
            case .record(let record):
                if let remoteDate = record.modifiedAt, remoteDate > (project.modifiedAt ?? .distantPast) {
                    let name = uniqueName(record.name, excluding: record.id, among: local, accepted: result)
                    result.append(project.replacingDefinition(with: record, name: name, home: home, honorsSharedImages: honorsSharedImages))
                } else {
                    var kept = project
                    if (record.modifiedAt ?? .distantPast) >= (project.modifiedAt ?? .distantPast) {
                        kept.isShared = true
                    }
                    result.append(kept)
                }
            }
        }

        let incoming = remote
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .compactMap { id, entry -> ProjectSyncRecord? in
                guard !handled.contains(id), case .record(let record) = entry else { return nil }
                return record
            }
        for record in incoming {
            var project = Project(syncRecord: record, home: home, honorsSharedImages: honorsSharedImages)
            let name = uniqueName(record.name, excluding: record.id, among: local, accepted: result)
            if name != record.name {
                logger.notice("shared project name collides with a local project; renamed on this Mac")
            }
            project.name = name
            result.append(project)
        }
        return result
    }

    private static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func uniqueName(_ name: String, excluding id: UUID, among local: [Project], accepted: [Project]) -> String {
        let taken = Set((local.filter { $0.id != id } + accepted.filter { $0.id != id }).map { key($0.name) })
        guard taken.contains(key(name)) else { return name }
        var counter = 2
        while taken.contains(key("\(name) \(counter)")) { counter += 1 }
        return "\(name) \(counter)"
    }
}
