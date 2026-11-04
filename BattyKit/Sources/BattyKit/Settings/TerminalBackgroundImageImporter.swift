// TerminalBackgroundImageImporter.swift

import CoreGraphics
import CryptoKit
import Darwin
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

    enum Cleanup: Sendable {
        /// App-wide copies are a setting: remove every folder except the one
        /// holding the path in use, which `importImage` is told about.
        case allButRetained
        /// Pane copies live in a folder named for this process, because Pane
        /// overrides aren't persisted: remove sibling folders whose name isn't
        /// a live process, so another running copy keeps its images.
        case deadProcessFolders
        /// Project copies outlive any one import and the keep-set lives on the
        /// main actor, so nothing happens during an import.
        /// `removeUnreferenced(keeping:olderThan:)` does this rule's work.
        case unreferenced
    }

    private let directory: URL
    private let cleanup: Cleanup
    private let isProcessAlive: @Sendable (Int32) -> Bool
    private var hasCleaned = false

    init(
        directory: URL,
        cleanup: Cleanup,
        isProcessAlive: @escaping @Sendable (Int32) -> Bool = TerminalBackgroundImageImporter.processIsAlive
    ) {
        self.directory = directory
        self.cleanup = cleanup
        self.isProcessAlive = isProcessAlive
    }

    /// `EPERM` means the process exists under another user.
    nonisolated static func processIsAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// For Pane overrides: per variant and per process.
    nonisolated static func defaultDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let bundleID = Bundle.main.bundleIdentifier ?? ServiceNames.appBundleIdentifier
        return caches
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("TerminalBackgrounds", isDirectory: true)
            .appendingPathComponent(String(ProcessInfo.processInfo.processIdentifier), isDirectory: true)
    }

    /// For the app-wide default: per variant, and in Application Support
    /// because Caches can be purged and this is a setting.
    @MainActor static func appWideDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent(SessionNameCache.resolvedDirectoryName(), isDirectory: true)
            .appendingPathComponent("TerminalBackgrounds", isDirectory: true)
    }

    /// Whether `path` is a copy this importer wrote and nothing has changed
    /// since: exactly `<directory>/<64 lowercase hex>/<name>.png`, compared by
    /// component with no standardizing so `..` fails, whose SHA-256 is its
    /// folder's name.
    nonisolated static func inspect(path: String, directory: URL) -> BackgroundImageState {
        let root = (directory.path as NSString).pathComponents
        let components = (path as NSString).pathComponents
        guard components.count == root.count + 2,
              Array(components.prefix(root.count)) == root,
              isDigest(components[root.count]),
              components[root.count + 1] != "..",
              components[root.count + 1].hasSuffix(".png")
        else { return .rejected }
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return .rejected }
        return hexDigest(of: bytes) == components[root.count] ? .usable : .rejected
    }

    private nonisolated static func isDigest(_ name: String) -> Bool {
        name.utf8.count == 64 && name.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private nonisolated static func hexDigest(of bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns the path of the PNG copy, in a folder named for the copy's own
    /// digest. Throws, leaving nothing behind, when ImageIO can't decode
    /// `source`. A copy already there is reused only if it is intact, so
    /// picking an image again repairs a damaged one.
    func importImage(from source: URL, retaining: String? = nil) throws -> String {
        cleanUpIfNeeded(retaining: retaining)

        let image = try Self.decode(try Data(contentsOf: source))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.writePNG(image, to: temporary)

        let digest = Self.hexDigest(of: try Data(contentsOf: temporary, options: .mappedIfSafe))
        let folder = directory.appendingPathComponent(digest, isDirectory: true)
        let destination = folder.appendingPathComponent(Self.fileName(for: source))
        if FileManager.default.fileExists(atPath: destination.path) {
            if Self.inspect(path: destination.path, directory: directory) == .usable {
                Self.refreshDate(ofFolderHolding: destination.path)
                return destination.path
            }
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        logger.info("imported background image to \(destination.path, privacy: .private)")
        return destination.path
    }

    private func cleanUpIfNeeded(retaining: String?) {
        guard !hasCleaned else { return }
        hasCleaned = true
        let fileManager = FileManager.default
        switch cleanup {
        case .allButRetained:
            let retainedFolder = retaining.map { ($0 as NSString).deletingLastPathComponent }
            for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] {
                let entry = directory.appendingPathComponent(name)
                if entry.path != retainedFolder { remove(entry) }
            }
        case .deadProcessFolders:
            let parent = directory.deletingLastPathComponent()
            for name in (try? fileManager.contentsOfDirectory(atPath: parent.path)) ?? [] {
                guard name != directory.lastPathComponent else { continue }
                if let pid = Int32(name), pid > 0, isProcessAlive(pid) { continue }
                remove(parent.appendingPathComponent(name))
            }
        case .unreferenced:
            break
        }
    }

    /// Removes digest folders of this directory that hold no kept path and were
    /// last modified before `cutoff`. Only an `.unreferenced` importer does this.
    func removeUnreferenced(keeping paths: Set<String>, olderThan cutoff: Date) {
        guard case .unreferenced = cleanup else { return }
        let fileManager = FileManager.default
        let keptFolders = Set(paths.map { ($0 as NSString).deletingLastPathComponent })
        for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] where Self.isDigest(name) {
            let entry = directory.appendingPathComponent(name, isDirectory: true)
            guard !keptFolders.contains(entry.path),
                  let modified = (try? fileManager.attributesOfItem(atPath: entry.path))?[.modificationDate] as? Date,
                  modified < cutoff
            else { continue }
            remove(entry)
        }
    }

    /// Returns a path in `directory` holding the same bytes as `path`, or nil
    /// unless `path` is already an intact copy there or in one of `sources`. A
    /// copy's folder is named for its bytes, so no re-encoding is needed, and a
    /// damaged destination is replaced.
    nonisolated static func adopt(path: String, from sources: [URL], into directory: URL) -> String? {
        if inspect(path: path, directory: directory) == .usable {
            refreshDate(ofFolderHolding: path)
            return path
        }
        guard sources.contains(where: { inspect(path: path, directory: $0) == .usable }) else { return nil }
        let components = (path as NSString).pathComponents
        let folder = directory.appendingPathComponent(components[components.count - 2], isDirectory: true)
        let destination = folder.appendingPathComponent(components[components.count - 1])
        if inspect(path: destination.path, directory: directory) == .usable {
            refreshDate(ofFolderHolding: destination.path)
            return destination.path
        }

        let fileManager = FileManager.default
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: temporary) }
            try fileManager.copyItem(at: URL(fileURLWithPath: path), to: temporary)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
            return destination.path
        } catch {
            logger.error("could not copy a background image: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    /// `removeUnreferenced` goes by the folder's date, and reusing a folder
    /// doesn't change it, so a copy reused today would look unused to another
    /// running copy. A failure here leaves the import good.
    private nonisolated static func refreshDate(ofFolderHolding path: String) {
        let folder = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: folder)
        } catch {
            logger.error("could not refresh a background image's date: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func remove(_ entry: URL) {
        do {
            try FileManager.default.removeItem(at: entry)
        } catch {
            logger.error("could not clear an earlier background image: \(error.localizedDescription, privacy: .private)")
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
