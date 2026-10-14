// ProjectSync.swift

import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "ProjectSync")

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

    public init(
        id: UUID, name: String, rootPath: String, color: SessionColor, symbol: ProjectSymbol,
        layout: ProjectLayout, runStartupCommandsOnOpen: Bool, modifiedAt: Date?
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.color = color
        self.symbol = symbol
        self.layout = layout
        self.runStartupCommandsOnOpen = runStartupCommandsOnOpen
        self.modifiedAt = modifiedAt
    }
}

extension Project {
    public func syncRecord(home: String) -> ProjectSyncRecord {
        ProjectSyncRecord(
            id: id, name: name,
            rootPath: PortablePath.encode(absolute: rootPath, home: home),
            color: color, symbol: symbol, layout: layout,
            runStartupCommandsOnOpen: runStartupCommandsOnOpen,
            modifiedAt: modifiedAt)
    }

    /// A shared Project with no device state. A root that does not decode to
    /// an absolute path (a `~user/...` form) is anchored at `/`, so the
    /// Project is kept and shows as missing-folder instead of being dropped.
    public init(syncRecord record: ProjectSyncRecord, home: String) {
        let decoded = PortablePath.decode(portable: record.rootPath, home: home)
        self.init(
            id: record.id, name: record.name,
            rootPath: decoded.hasPrefix("/") ? decoded : "/" + decoded,
            color: record.color, symbol: record.symbol, layout: record.layout,
            runStartupCommandsOnOpen: record.runStartupCommandsOnOpen,
            approvedCommandsHash: nil, lastOpenedAt: nil,
            isShared: true, modifiedAt: record.modifiedAt)
    }

    fileprivate func replacingDefinition(with record: ProjectSyncRecord, name: String, home: String) -> Project {
        var merged = Project(syncRecord: record, home: home)
        merged.name = name
        merged.approvedCommandsHash = approvedCommandsHash
        merged.lastOpenedAt = lastOpenedAt
        return merged
    }
}

public enum ProjectSyncEntry: Sendable, Equatable {
    case record(ProjectSyncRecord)
    case tombstone(deletedAt: Date)
}

/// Where shared Project records go. Phase (a) ships only the local-only
/// implementation; an iCloud backend plugs in behind the same protocol.
@MainActor
public protocol ProjectSyncBackend: AnyObject {
    var isAvailable: Bool { get }
    func snapshot() -> [UUID: ProjectSyncEntry]
    func publish(_ record: ProjectSyncRecord)
    /// Unshare: the entry is removed and other Macs keep their copy as local.
    func withdraw(id: UUID)
    /// Delete: the entry becomes a tombstone other Macs apply.
    func tombstone(id: UUID, deletedAt: Date)
    var changes: AsyncStream<Void> { get }
}

/// Keeps entries in memory and never touches disk or the network.
@MainActor
public final class LocalOnlyProjectSyncBackend: ProjectSyncBackend {
    public enum Call: Sendable, Equatable {
        case publish(ProjectSyncRecord)
        case withdraw(UUID)
        case tombstone(UUID, Date)
    }

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
        now: Date
    ) -> [Project] {
        var result: [Project] = []
        var handled = Set<UUID>()

        for project in local {
            guard let entry = remote[project.id] else {
                // Absent from the remote set: withdrawn elsewhere. Kept as local, never deleted.
                var kept = project
                if kept.isShared { kept.isShared = false }
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
                    result.append(project.replacingDefinition(with: record, name: name, home: home))
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
            var project = Project(syncRecord: record, home: home)
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
