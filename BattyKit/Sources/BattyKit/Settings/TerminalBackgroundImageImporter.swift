// TerminalBackgroundImageImporter.swift

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "TerminalBackgroundImageImporter")

/// Re-encodes a user's image into a Batty-owned PNG, and that copy's path is
/// what libghostty gets, never the user's file. Measured against the pinned
/// `libghostty.a` (#0374): a PNG with one flipped bit or a truncated PNG or
/// JPEG passes ImageIO and makes `ghostty_surface_new` return `NULL`, and an
/// image wider than 16384 px aborts the process, on a live surface too. No
/// check made from outside can match libghostty's stricter decoder, so the
/// importer removes the mismatch instead of testing for it.
actor TerminalBackgroundImageImporter {
    enum ImportError: Error {
        case undecodable
        case encodingFailed
    }

    /// Below the measured 16384 abort, and upstream keeps one copy of the
    /// image per terminal: 4096x3072 is about 50 MB per Tab.
    static let maxPixelSize = 4096

    private let directory: URL
    private var hasClearedEarlierRuns = false

    init(directory: URL) {
        self.directory = directory
    }

    /// Per variant, so Prod and Beta never clear each other's files.
    nonisolated static func defaultDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let bundleID = Bundle.main.bundleIdentifier ?? ServiceNames.appBundleIdentifier
        return caches
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("TerminalBackgrounds", isDirectory: true)
    }

    /// Returns the path of the PNG copy. Throws, leaving nothing behind, when
    /// ImageIO can't decode `source`.
    func importImage(from source: URL) throws -> String {
        clearEarlierRunsIfNeeded()

        let bytes = try Data(contentsOf: source)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let folder = directory.appendingPathComponent(digest, isDirectory: true)
        let destination = folder.appendingPathComponent(Self.fileName(for: source))
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination.path
        }

        let image = try Self.decode(bytes)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.writePNG(image, to: temporary)
        try FileManager.default.moveItem(at: temporary, to: destination)
        logger.info("imported background image to \(destination.path, privacy: .private)")
        return destination.path
    }

    /// Overrides aren't persisted, so nothing can reference an earlier run's
    /// files.
    private func clearEarlierRunsIfNeeded() {
        guard !hasClearedEarlierRuns else { return }
        hasClearedEarlierRuns = true
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            logger.error("could not clear earlier background images: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Keeps the source's name for display. A quote or backslash is dropped
    /// because the path is written into a quoted config value. The bound is in
    /// bytes because APFS limits a name to 255 of them.
    private static func fileName(for source: URL) -> String {
        var name = String(String.UnicodeScalarView(
            source.deletingPathExtension().lastPathComponent.unicodeScalars.filter {
                $0.properties.generalCategory != .control && $0 != "\"" && $0 != "\\"
            }
        ))
        while name.utf8.count > 200 { name.removeLast() }
        return (name.isEmpty ? "image" : name) + ".png"
    }

    private static func decode(_ bytes: Data) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let imageSource = CGImageSourceCreateWithData(bytes as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary)
        else { throw ImportError.undecodable }
        return thumbnail
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { throw ImportError.encodingFailed }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let flattened = context.makeImage(),
              let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ImportError.encodingFailed }
        CGImageDestinationAddImage(output, flattened, nil)
        guard CGImageDestinationFinalize(output) else { throw ImportError.encodingFailed }
    }
}
