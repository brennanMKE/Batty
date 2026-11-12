// DownloadedImageCache.swift

import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "DownloadedImageCache")

/// One image the cache holds. `url` is set for a Background Sets image only.
public nonisolated struct DownloadedImageEntry: Codable, Sendable, Equatable {
    public var digest: String
    public var url: URL?
    public var name: String
    public var bytes: Int64
    public var lastUsedAt: Date
}

/// `Downloaded/downloaded-images.json`.
nonisolated struct DownloadedImageIndex: Codable, Sendable, Equatable {
    var version = 1
    var entries: [DownloadedImageEntry]

    static let fileName = "downloaded-images.json"

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)))
        }
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            if let date = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) { return date }
            if let date = try? Date(text, strategy: .iso8601) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an ISO 8601 date")
        }
        return decoder
    }

    /// Nil when the file is absent or doesn't decode.
    static func read(in directory: URL) -> DownloadedImageIndex? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        guard let index = try? decoder.decode(DownloadedImageIndex.self, from: data) else {
            logger.error("unreadable downloaded image index; treating it as empty")
            return nil
        }
        return index
    }

    /// A synchronous read of the small index, for callers on the main actor.
    static func entries(in directory: URL) -> [DownloadedImageEntry] {
        read(in: directory)?.entries ?? []
    }
}

/// Images fetched because a synced Tab selection named them. Bounded and least
/// recently used first; an image in use is never evicted. Never joins My
/// Images, and nothing else deletes from it.
actor DownloadedImageCache {
    struct Limits: Sendable, Equatable {
        var count: Int
        var bytes: Int64

        static let standard = Limits(count: 20, bytes: 500_000_000)
    }

    /// A stored image and what its insert evicted.
    struct Insertion: Sendable, Equatable {
        var path: String
        var evicted: [String]
    }

    nonisolated let directory: URL
    nonisolated let limits: Limits
    private let fetcher: BackgroundCatalogFetching
    private let temporaryRoot: URL
    private let now: @Sendable () -> Date
    private var entries: [DownloadedImageEntry] = []
    private var isLoaded = false
    private var warnedOverBound = false

    nonisolated static func directory(inLibrary library: URL) -> URL {
        library.appendingPathComponent("Downloaded", isDirectory: true)
    }

    init(
        directory: URL,
        fetcher: BackgroundCatalogFetching,
        temporaryRoot: URL,
        limits: Limits = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.directory = directory
        self.fetcher = fetcher
        self.temporaryRoot = temporaryRoot
        self.limits = limits
        self.now = now
    }

    func allEntries() -> [DownloadedImageEntry] {
        loadIfNeeded()
        return entries
    }

    func path(forDigest digest: String) -> String? {
        loadIfNeeded()
        guard entries.contains(where: { $0.digest == digest }) else { return nil }
        return TerminalBackgroundImageImporter.existingCopy(digest: digest, in: directory)
    }

    func path(forURL url: URL) -> String? {
        loadIfNeeded()
        guard let entry = entries.last(where: { $0.url == url }) else { return nil }
        return path(forDigest: entry.digest)
    }

    func touch(digest: String) {
        loadIfNeeded()
        guard let index = entries.firstIndex(where: { $0.digest == digest }) else { return }
        entries[index].lastUsedAt = now()
        save()
    }

    /// Downloads through a `HostedImageStore` on this folder, so every size,
    /// type, pixel and import check applies unchanged. Its own record file is
    /// only a hint; this cache's index is the authority.
    func fetchHosted(url: URL, name: String, allowedHosts: Set<String>, pinned: Set<String>) async throws(HostedImageError) -> Insertion {
        guard let host = url.host?.lowercased(), allowedHosts.contains(host), ProjectTabImage.isAcceptable(url) else {
            throw .disallowedHost
        }
        if let held = path(forURL: url), let digest = TerminalBackgroundImageImporter.digest(ofPath: held) {
            touch(digest: digest)
            return Insertion(path: held, evicted: [])
        }
        let store = HostedImageStore(directory: directory, fetcher: fetcher, temporaryRoot: temporaryRoot, now: now)
        let path = try await store.fetch(HostedBackgroundImage(title: name, full: url, thumbnail: url))
        guard let digest = TerminalBackgroundImageImporter.digest(ofPath: path) else { throw .importFailed }
        return insert(digest: digest, url: url, name: name, path: path, pinned: pinned)
    }

    /// For bytes already checked against `digest`.
    func insertVerified(bytes: Data, digest: String, name: String, pinned: Set<String>) -> Insertion? {
        loadIfNeeded()
        if let held = path(forDigest: digest) {
            touch(digest: digest)
            return Insertion(path: held, evicted: [])
        }
        guard TerminalBackgroundImageImporter.storeVerified(bytes: bytes, digest: digest, name: name, into: directory) == .usable,
              let path = TerminalBackgroundImageImporter.existingCopy(digest: digest, in: directory)
        else { return nil }
        return insert(digest: digest, url: nil, name: name, path: path, pinned: pinned)
    }

    func remove(digest: String) {
        loadIfNeeded()
        entries.removeAll { $0.digest == digest }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(digest, isDirectory: true))
        save()
    }

    private func insert(digest: String, url: URL?, name: String, path: String, pinned: Set<String>) -> Insertion {
        loadIfNeeded()
        let entry = DownloadedImageEntry(digest: digest, url: url, name: name, bytes: Self.size(of: path), lastUsedAt: now())
        if let index = entries.firstIndex(where: { $0.digest == digest }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        let evicted = evict(pinned: pinned.union([digest]))
        save()
        return Insertion(path: path, evicted: evicted)
    }

    /// Oldest first, ties by digest. Stops over the bound when only pinned
    /// images are left; the next insert tries again.
    private func evict(pinned: Set<String>) -> [String] {
        var evicted: [String] = []
        while entries.count > limits.count || entries.reduce(0, { $0 + $1.bytes }) > limits.bytes {
            let candidates = entries.filter { !pinned.contains($0.digest) }
            guard let victim = candidates.min(by: { ($0.lastUsedAt, $0.digest) < ($1.lastUsedAt, $1.digest) }) else {
                if !warnedOverBound {
                    warnedOverBound = true
                    logger.notice("downloaded image cache is over its bound with only images in use")
                }
                break
            }
            if let path = TerminalBackgroundImageImporter.existingCopy(digest: victim.digest, in: directory) { evicted.append(path) }
            entries.removeAll { $0.digest == victim.digest }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(victim.digest, isDirectory: true))
        }
        return evicted
    }

    /// Once per launch: an entry whose folder is gone is dropped, and a digest
    /// folder with no entry is indexed as least recently used.
    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        let stored = DownloadedImageIndex.read(in: directory)?.entries ?? []
        var reconciled = stored.filter { TerminalBackgroundImageImporter.existingCopy(digest: $0.digest, in: directory) != nil }
        let known = Set(reconciled.map(\.digest))
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for folder in folders.sorted() where TerminalBackgroundImageImporter.isDigest(folder) && !known.contains(folder) {
            guard let path = TerminalBackgroundImageImporter.existingCopy(digest: folder, in: directory) else { continue }
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            reconciled.append(DownloadedImageEntry(digest: folder, url: nil, name: name, bytes: Self.size(of: path), lastUsedAt: .distantPast))
        }
        entries = reconciled
        if reconciled != stored { save() }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try DownloadedImageIndex.encoder.encode(DownloadedImageIndex(entries: entries))
            try data.write(to: directory.appendingPathComponent(DownloadedImageIndex.fileName), options: .atomic)
        } catch {
            logger.error("could not write the downloaded image index: \(error.localizedDescription, privacy: .private)")
        }
    }

    private static func size(of path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
