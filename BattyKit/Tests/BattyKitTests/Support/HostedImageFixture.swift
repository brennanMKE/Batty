// HostedImageFixture.swift

import Foundation
import Testing
@testable import BattyKit

/// A temporary hosted store, catalog cache and download folder behind a fake
/// fetcher. Nothing touches `~/Library/Caches` or the network.
@MainActor
final class HostedImageFixture {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("batty-hosted-\(UUID().uuidString)", isDirectory: true)
    let fetcher = FakeBackgroundCatalogFetcher()
    let catalogURL = BackgroundCatalog.builtInURL

    var hostedFolder: URL { base.appendingPathComponent("BackgroundImages/Hosted", isDirectory: true) }
    var temporaryRoot: URL { base.appendingPathComponent("downloads", isDirectory: true) }
    var cacheRoot: URL { base.appendingPathComponent("BackgroundCatalogs", isDirectory: true) }

    lazy var store = HostedImageStore(directory: hostedFolder, fetcher: fetcher, temporaryRoot: temporaryRoot)
    lazy var cache = BackgroundCatalogCache(root: cacheRoot)

    @MainActor deinit {
        try? FileManager.default.removeItem(at: base)
    }

    func url(_ name: String) -> URL {
        URL(string: "https://batty.sstools.co/backgrounds/\(name)")!
    }

    /// An image whose full file is `data`, served by the fake.
    func image(
        id: String = "harbor-01",
        title: String = "Harbor at Night",
        data: Data,
        fileExtension: String = "png",
        thumbnail: Data? = nil
    ) -> HostedBackgroundImage {
        let fullURL = url("\(id).\(fileExtension)")
        let thumbURL = url("\(id)-thumb.png")
        fetcher.set(.ok(data), for: fullURL)
        if let thumbnail { fetcher.set(.ok(thumbnail, etag: "\"t-\(id)\""), for: thumbURL) }
        return HostedBackgroundImage(title: title, full: fullURL, thumbnail: thumbURL)
    }

    func digestFolders() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: hostedFolder.path)) ?? [])
            .filter(TerminalBackgroundImageImporter.isDigest)
    }

    func temporaryContents() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path)) ?? []
    }

    /// Rewrites a PNG's IHDR width and height and recomputes the chunk's CRC.
    static func patchingIHDR(_ png: Data, width: UInt32, height: UInt32) -> Data {
        var bytes = [UInt8](png)
        func put(_ value: UInt32, at offset: Int) {
            bytes[offset] = UInt8(value >> 24 & 0xFF)
            bytes[offset + 1] = UInt8(value >> 16 & 0xFF)
            bytes[offset + 2] = UInt8(value >> 8 & 0xFF)
            bytes[offset + 3] = UInt8(value & 0xFF)
        }
        put(width, at: 16)
        put(height, at: 20)
        put(crc32(bytes[12..<29]), at: 29)
        return Data(bytes)
    }

    private static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
