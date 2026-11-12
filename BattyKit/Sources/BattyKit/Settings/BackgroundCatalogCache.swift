// BackgroundCatalogCache.swift

import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "BackgroundCatalogCache")

nonisolated struct HostedValidators: Sendable, Equatable, Codable {
    var etag: String?
    var lastModified: String?
}

nonisolated struct BackgroundCatalogCacheState: Sendable, Equatable, Codable {
    var etag: String?
    var lastModified: String?
    var lastChecked: Date?
    var lastError: String?

    var validators: HostedValidators { HostedValidators(etag: etag, lastModified: lastModified) }
}

nonisolated struct CachedCatalog: Sendable, Equatable {
    let catalog: BackgroundCatalog
    let state: BackgroundCatalogCacheState
}

nonisolated struct CachedThumbnailMetadata: Sendable, Equatable, Codable {
    let url: URL
    let etag: String?
    let lastModified: String?
}

nonisolated struct CachedThumbnail: Sendable, Equatable {
    let file: URL
    let metadata: CachedThumbnailMetadata
}

/// A pure cache: anything missing or unreadable reads as absent, never as an error.
actor BackgroundCatalogCache {
    nonisolated let root: URL

    init(root: URL) {
        self.root = root
    }

    nonisolated static func defaultRoot() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let bundleID = Bundle.main.bundleIdentifier ?? ServiceNames.appBundleIdentifier
        return caches
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("BackgroundCatalogs", isDirectory: true)
    }

    nonisolated func folder(for catalogURL: URL) -> URL {
        let name = TerminalBackgroundImageImporter.hexDigest(of: Data(catalogURL.absoluteString.utf8))
        return root.appendingPathComponent(name, isDirectory: true)
    }

    /// A stored copy that no longer parses is ignored.
    func cachedCatalog(for catalogURL: URL) -> CachedCatalog? {
        let folder = folder(for: catalogURL)
        guard let body = try? Data(contentsOf: folder.appendingPathComponent("catalog.json")),
              let catalog = try? BackgroundCatalogParser.parse(body, catalogURL: catalogURL)
        else { return nil }
        return CachedCatalog(catalog: catalog, state: state(for: catalogURL))
    }

    func state(for catalogURL: URL) -> BackgroundCatalogCacheState {
        let file = folder(for: catalogURL).appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: file),
              let state = try? JSONDecoder().decode(BackgroundCatalogCacheState.self, from: data)
        else { return BackgroundCatalogCacheState() }
        return state
    }

    func store(body: Data, validators: HostedValidators, for catalogURL: URL, at date: Date) {
        let folder = folder(for: catalogURL)
        write(body, to: folder.appendingPathComponent("catalog.json"))
        writeState(BackgroundCatalogCacheState(etag: validators.etag, lastModified: validators.lastModified, lastChecked: date, lastError: nil), for: catalogURL)
    }

    func markChecked(for catalogURL: URL, at date: Date, error: String?) {
        var current = state(for: catalogURL)
        current.lastChecked = date
        current.lastError = error
        writeState(current, for: catalogURL)
    }

    /// Thumbnails are filed by a hash of the image's full-size URL.
    nonisolated func thumbnailFile(for catalogURL: URL, image: URL) -> URL {
        folder(for: catalogURL)
            .appendingPathComponent("thumbnails", isDirectory: true)
            .appendingPathComponent(TerminalBackgroundImageImporter.hexDigest(of: Data(image.absoluteString.utf8)))
    }

    func thumbnail(for catalogURL: URL, image: URL) -> CachedThumbnail? {
        let file = thumbnailFile(for: catalogURL, image: image)
        guard FileManager.default.fileExists(atPath: file.path),
              let data = try? Data(contentsOf: file.appendingPathExtension("json")),
              let metadata = try? JSONDecoder().decode(CachedThumbnailMetadata.self, from: data)
        else { return nil }
        return CachedThumbnail(file: file, metadata: metadata)
    }

    @discardableResult
    func storeThumbnail(_ body: Data, metadata: CachedThumbnailMetadata, for catalogURL: URL, image: URL) -> URL? {
        guard let encoded = try? JSONEncoder().encode(metadata) else { return nil }
        let file = thumbnailFile(for: catalogURL, image: image)
        guard write(body, to: file) else { return nil }
        write(encoded, to: file.appendingPathExtension("json"))
        return file
    }

    func removeAll(for catalogURL: URL) {
        let folder = folder(for: catalogURL)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            logger.error("could not remove a catalog cache: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func writeState(_ state: BackgroundCatalogCacheState, for catalogURL: URL) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        write(data, to: folder(for: catalogURL).appendingPathComponent("state.json"))
    }

    @discardableResult
    private func write(_ data: Data, to file: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return true
        } catch {
            logger.error("could not write the catalog cache: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }
}
