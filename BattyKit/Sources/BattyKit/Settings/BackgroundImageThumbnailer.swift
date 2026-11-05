// BackgroundImageThumbnailer.swift

import CoreGraphics
import Foundation
import ImageIO

/// `@unchecked` because a `CGImage` is immutable once made.
nonisolated struct BackgroundImageThumbnail: @unchecked Sendable {
    let image: CGImage?
    let state: BackgroundImageState
}

/// Makes the Background Images window's pictures off the main actor, and decodes
/// only a file whose digest and header have passed, so nothing over the importer's
/// limit is ever decoded. Downsamples from the file URL, keeping no full bitmap.
actor BackgroundImageThumbnailer {
    static let maxThumbnailPixelSize = 360

    private final class Memo {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let decode: @Sendable (URL) -> CGImage?
    private let memo: NSCache<NSString, Memo> = {
        let cache = NSCache<NSString, Memo>()
        cache.countLimit = 200
        return cache
    }()

    init(decode: @escaping @Sendable (URL) -> CGImage? = BackgroundImageThumbnailer.downsample) {
        self.decode = decode
    }

    /// Memoized by digest, because a digest's bytes don't change.
    func thumbnail(for entry: BackgroundImageEntry) -> BackgroundImageThumbnail {
        if let known = memo.object(forKey: entry.digest as NSString) {
            return BackgroundImageThumbnail(image: known.image, state: .usable)
        }
        let digestFolder = (entry.path as NSString).deletingLastPathComponent
        let root = URL(fileURLWithPath: (digestFolder as NSString).deletingLastPathComponent, isDirectory: true)
        let state = TerminalBackgroundImageImporter.inspect(path: entry.path, directory: root)
        guard state == .usable else { return BackgroundImageThumbnail(image: nil, state: state) }
        guard TerminalBackgroundImageImporter.isWithinPixelLimit(path: entry.path),
              let image = decode(URL(fileURLWithPath: entry.path))
        else { return BackgroundImageThumbnail(image: nil, state: .rejected) }
        memo.setObject(Memo(image), forKey: entry.digest as NSString)
        return BackgroundImageThumbnail(image: image, state: .usable)
    }

    nonisolated static func downsample(_ url: URL) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxThumbnailPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
