// SessionNameCache.swift

import Foundation
import Observation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "SessionNameCache")

public struct SessionNameCacheEntry: Codable, Sendable, Hashable {
    public var path: String
    public var name: String
    public var lastUsedAt: Date

    public init(path: String, name: String, lastUsedAt: Date) {
        self.path = path
        self.name = name
        self.lastUsedAt = lastUsedAt
    }
}

struct SessionNameCacheFile: Codable, Sendable, Hashable {
    static let currentSchemaVersion: Int = 1

    var version: Int
    var entries: [SessionNameCacheEntry]

    init(version: Int = SessionNameCacheFile.currentSchemaVersion, entries: [SessionNameCacheEntry] = []) {
        self.version = version
        self.entries = entries
    }
}

extension SessionNameCacheFile {
    static let prettyEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

@MainActor
@Observable
public final class SessionNameCache {
    public static let defaultDirectoryName = "Batty"
    public static let defaultFileName = "session-name-cache.json"
    public static let entryCap: Int = 100
    public static let defaultDebounce: Duration = .milliseconds(250)

    private var entriesByPath: [String: SessionNameCacheEntry]
    private let fileURL: URL?
    private let fileManager: FileManager
    private let debounce: Duration
    private let clock: () -> Date
    @ObservationIgnored private var pendingSaveTask: Task<Void, Never>?

    public init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        debounce: Duration = SessionNameCache.defaultDebounce,
        clock: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.debounce = debounce
        self.clock = clock
        let resolvedURL: URL?
        if let fileURL {
            resolvedURL = fileURL
        } else {
            resolvedURL = try? Self.canonicalFileURL(fileManager: fileManager)
        }
        self.fileURL = resolvedURL
        self.entriesByPath = Self.loadFromDisk(fileURL: resolvedURL, fileManager: fileManager)
    }

    public static func canonicalFileURL(fileManager: FileManager = .default) throws -> URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw SessionNameCacheError.applicationSupportUnavailable
        }
        let dir = appSupport.appendingPathComponent(defaultDirectoryName, isDirectory: true)
        return dir.appendingPathComponent(defaultFileName)
    }

    public var url: URL? { fileURL }

    public var entryCount: Int { entriesByPath.count }

    public func lookup(path: String) -> String? {
        guard !path.isEmpty else { return nil }
        guard var entry = entriesByPath[path] else { return nil }
        entry.lastUsedAt = clock()
        entriesByPath[path] = entry
        scheduleSave()
        return entry.name
    }

    public func removeName(forPath path: String) {
        guard entriesByPath[path] != nil else { return }
        entriesByPath.removeValue(forKey: path)
        scheduleSave()
    }

    public func record(path: String, name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !trimmedName.isEmpty else { return }
        let entry = SessionNameCacheEntry(path: path, name: trimmedName, lastUsedAt: clock())
        entriesByPath[path] = entry
        enforceCap()
        scheduleSave()
    }

    public func snapshot() -> [SessionNameCacheEntry] {
        entriesByPath.values.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    public func save() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        writeNow()
    }

    private func scheduleSave() {
        pendingSaveTask?.cancel()
        let debounce = self.debounce
        pendingSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: debounce)
            if Task.isCancelled { return }
            self?.writeNow()
        }
    }

    private func writeNow() {
        guard let fileURL else { return }
        let file = SessionNameCacheFile(entries: snapshot())
        do {
            try ensureContainerExists(for: fileURL)
            let data = try SessionNameCacheFile.prettyEncoder.encode(file)
            try writeAtomically(data: data, to: fileURL)
            logger.debug("session name cache saved (\(file.entries.count) entries, \(data.count) bytes)")
        } catch {
            logger.error("session name cache save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func enforceCap() {
        guard entriesByPath.count > Self.entryCap else { return }
        let sorted = entriesByPath.values.sorted { $0.lastUsedAt < $1.lastUsedAt }
        let dropCount = entriesByPath.count - Self.entryCap
        for entry in sorted.prefix(dropCount) {
            entriesByPath.removeValue(forKey: entry.path)
        }
    }

    private static func loadFromDisk(fileURL: URL?, fileManager: FileManager) -> [String: SessionNameCacheEntry] {
        guard let fileURL, fileManager.fileExists(atPath: fileURL.path) else { return [:] }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try SessionNameCacheFile.decoder.decode(SessionNameCacheFile.self, from: data)
            var byPath: [String: SessionNameCacheEntry] = [:]
            for entry in decoded.entries where !entry.path.isEmpty && !entry.name.isEmpty {
                byPath[entry.path] = entry
            }
            logger.debug("session name cache loaded (\(byPath.count) entries)")
            return byPath
        } catch {
            logger.error("session name cache load failed (\(error.localizedDescription, privacy: .public)); recovering empty")
            return [:]
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
        try data.write(to: tmp, options: [.atomic])
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: tmp)
        } else {
            try fileManager.moveItem(at: tmp, to: destination)
        }
    }
}

public enum SessionNameCacheError: Error, Sendable {
    case applicationSupportUnavailable
}
