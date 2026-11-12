// HostedThumbnailLoader.swift

import CoreGraphics
import Foundation

/// Thumbnails for hosted images, cached per catalog. Never touches the library
/// or the hosted store.
actor HostedThumbnailLoader {
    static let maxConcurrentFetches = 4

    private final class Memo {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let fetcher: BackgroundCatalogFetching
    private let cache: BackgroundCatalogCache
    private let decode: @Sendable (URL) -> CGImage?
    private let memo: NSCache<NSString, Memo> = {
        let cache = NSCache<NSString, Memo>()
        cache.countLimit = 300
        return cache
    }()
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(
        fetcher: BackgroundCatalogFetching,
        cache: BackgroundCatalogCache,
        decode: @escaping @Sendable (URL) -> CGImage? = BackgroundImageThumbnailer.downsample
    ) {
        self.fetcher = fetcher
        self.cache = cache
        self.decode = decode
    }

    func thumbnail(for image: HostedBackgroundImage, catalogURL: URL) async -> BackgroundImageThumbnail {
        let file = image.thumbnail
        let key = "\(catalogURL.absoluteString)\n\(image.full.absoluteString)\n\(file.absoluteString)" as NSString
        if let known = memo.object(forKey: key) {
            return BackgroundImageThumbnail(image: known.image, state: .usable)
        }
        // The catalog carries no checksum, so a cached copy not yet in memory is
        // revalidated with a conditional request, and used as is offline.
        let cached = await cache.thumbnail(for: catalogURL, image: image.full)

        await acquire()
        defer { release() }
        let sameURL = cached?.metadata.url == file
        let request = HostedFetchRequest(
            url: file,
            etag: sameURL ? cached?.metadata.etag : nil,
            lastModified: sameURL ? cached?.metadata.lastModified : nil,
            byteLimit: BackgroundCatalogLimits.thumbnailBytes,
            timeout: BackgroundCatalogLimits.thumbnailTimeout
        )
        let response: HostedFetchResponse
        do {
            response = try await fetcher.fetch(request, progress: nil)
        } catch {
            if (error == .unreachable || error == .timedOut), let cached, sameURL {
                return finish(cached.file, url: file, key: key)
            }
            return BackgroundImageThumbnail(image: nil, state: .rejected)
        }
        if response.status == 304, let cached, sameURL {
            return finish(cached.file, url: file, key: key)
        }
        guard response.status == 200, let body = response.body,
              Int64(body.count) <= BackgroundCatalogLimits.thumbnailBytes
        else { return BackgroundImageThumbnail(image: nil, state: .rejected) }
        let metadata = CachedThumbnailMetadata(url: file, etag: response.etag, lastModified: response.lastModified)
        guard let stored = await cache.storeThumbnail(body, metadata: metadata, for: catalogURL, image: image.full) else {
            return BackgroundImageThumbnail(image: nil, state: .rejected)
        }
        return finish(stored, url: file, key: key)
    }

    private func finish(_ file: URL, url: URL, key: NSString) -> BackgroundImageThumbnail {
        guard let header = HostedImageHeader.read(file),
              BackgroundCatalogLimits.isAccepted(type: header.type, for: url),
              max(header.width, header.height) <= BackgroundCatalogLimits.thumbnailPixels,
              let image = decode(file)
        else { return BackgroundImageThumbnail(image: nil, state: .rejected) }
        memo.setObject(Memo(image), forKey: key)
        return BackgroundImageThumbnail(image: image, state: .usable)
    }

    private func acquire() async {
        if running < Self.maxConcurrentFetches {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
