// HostedImageStore.swift

import Foundation
import ImageIO
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "HostedImageStore")

/// Keyed by the image's resolved full-size URL.
nonisolated struct HostedImageRecord: Sendable, Equatable, Codable {
    let url: URL
    let digest: String
    let fetchedAt: Date
}

nonisolated enum HostedImageError: Error, Equatable, Sendable {
    case fetch(HostedFetchError)
    case unsupportedType
    case tooManyPixels
    case importFailed
    case disallowedHost

    func message(host: String) -> String {
        switch self {
        case .fetch(let error): error.message(host: host)
        case .unsupportedType: "Not a PNG or JPEG image"
        case .tooManyPixels: "The image is too large"
        case .importFailed: "The image couldn't be read"
        case .disallowedHost: "Not a Background Sets address"
        }
    }
}

/// What an image file's header says, read without decoding any pixels.
nonisolated struct HostedImageHeader: Sendable, Equatable {
    let type: String
    let width: Int
    let height: Int

    var fileExtension: String { type == "public.jpeg" ? "jpg" : "png" }

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// A PNG's size comes straight from its IHDR, because ImageIO reports no
    /// properties at all for a header past its own limits, which would hide an
    /// oversized image as an unsupported one.
    static func read(_ url: URL) -> HostedImageHeader? {
        if let handle = try? FileHandle(forReadingFrom: url) {
            let prefix = [UInt8]((try? handle.read(upToCount: 24)) ?? Data())
            try? handle.close()
            if prefix.count == 24, Array(prefix[0..<8]) == pngSignature, Array(prefix[12..<16]) == Array("IHDR".utf8) {
                func value(at offset: Int) -> Int {
                    prefix[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
                }
                return HostedImageHeader(type: "public.png", width: value(at: 16), height: value(at: 20))
            }
        }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return HostedImageHeader(type: type, width: width, height: height)
    }
}

/// Full-size copies of hosted images, re-encoded by Batty's importer. Lives in
/// `BackgroundImages/Hosted/`, which the library never lists, so hosted images
/// stay in their sets instead of joining My Images.
actor HostedImageStore {
    nonisolated let directory: URL
    private let fetcher: BackgroundCatalogFetching
    private let temporaryRoot: URL
    private let importer: TerminalBackgroundImageImporter
    private let now: @Sendable () -> Date
    private let importImage: (@Sendable (URL) async throws -> String)?

    /// `importImage` is a test seam for counting decodes; nil uses the importer.
    init(
        directory: URL,
        fetcher: BackgroundCatalogFetching,
        temporaryRoot: URL,
        now: @escaping @Sendable () -> Date = Date.init,
        importImage: (@Sendable (URL) async throws -> String)? = nil
    ) {
        self.directory = directory
        self.fetcher = fetcher
        self.temporaryRoot = temporaryRoot
        self.importer = TerminalBackgroundImageImporter(directory: directory, cleanup: .keepAll)
        self.now = now
        self.importImage = importImage
    }

    nonisolated static func defaultTemporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("batty-hosted-downloads", isDirectory: true)
    }

    nonisolated var recordsFile: URL { directory.appendingPathComponent("hosted-images.json") }


    func records() -> [HostedImageRecord] {
        Self.records(in: directory)
    }

    /// A synchronous read of the small records file, for the main actor.
    nonisolated static func records(in directory: URL) -> [HostedImageRecord] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("hosted-images.json")),
              let records = try? JSONDecoder().decode([HostedImageRecord].self, from: data)
        else { return [] }
        return records
    }

    func digests() -> Set<String> {
        Set(records().map(\.digest))
    }

    func localPath(for image: HostedBackgroundImage) -> String? {
        guard let record = records().last(where: { $0.url == image.full }) else { return nil }
        return TerminalBackgroundImageImporter.existingCopy(digest: record.digest, in: directory)
    }

    /// Checks size, type and header dimensions before any pixel is decoded,
    /// and keeps nothing when one fails.
    func fetch(_ image: HostedBackgroundImage) async throws(HostedImageError) -> String {
        if let path = localPath(for: image) { return path }
        let limit = BackgroundCatalogLimits.fullBytes

        let fileManager = FileManager.default
        let folder = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: folder) }
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw .importFailed
        }
        let download = folder.appendingPathComponent("download")
        let request = HostedFetchRequest(
            url: image.full,
            byteLimit: limit,
            timeout: BackgroundCatalogLimits.fullTimeout,
            destination: .file(download)
        )
        let response: HostedFetchResponse
        do {
            response = try await fetcher.fetch(request, progress: nil)
        } catch {
            throw .fetch(error)
        }
        guard response.status == 200 else { throw .fetch(HostedFetchPolicy.error(forStatus: response.status) ?? .http(response.status)) }
        if let body = response.body, !fileManager.fileExists(atPath: download.path) {
            do { try body.write(to: download) } catch { throw .importFailed }
        }
        let size = ((try? fileManager.attributesOfItem(atPath: download.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= limit else { throw .fetch(.tooLarge) }
        guard let header = HostedImageHeader.read(download),
              BackgroundCatalogLimits.isAccepted(type: header.type, for: image.full)
        else { throw .unsupportedType }
        guard max(header.width, header.height) <= BackgroundCatalogLimits.fullPixels else { throw .tooManyPixels }

        let named = folder.appendingPathComponent(
            TerminalBackgroundImageImporter.sanitizedImageName(image.title) + "." + header.fileExtension
        )
        let path: String
        do {
            try fileManager.moveItem(at: download, to: named)
            if let importImage {
                path = try await importImage(named)
            } else {
                path = try await importer.importImage(from: named)
            }
        } catch {
            logger.error("could not import a hosted image: \(error.localizedDescription, privacy: .private)")
            throw .importFailed
        }
        guard let digest = TerminalBackgroundImageImporter.digest(ofPath: path) else { throw .importFailed }
        var updated = records().filter { $0.url != image.full }
        updated.append(HostedImageRecord(url: image.full, digest: digest, fetchedAt: now()))
        writeRecords(updated)
        return path
    }

    /// Leaves every `Hosted/<digest>/` folder: deleting one would let the
    /// library's next scan promote a use's copy of it into My Images.
    func removeRecords(for fullURLs: Set<URL>) {
        let current = records()
        let kept = current.filter { !fullURLs.contains($0.url) }
        guard kept.count != current.count else { return }
        writeRecords(kept)
    }

    private func writeRecords(_ records: [HostedImageRecord]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: recordsFile, options: .atomic)
        } catch {
            logger.error("could not write hosted image records: \(error.localizedDescription, privacy: .private)")
        }
    }
}
