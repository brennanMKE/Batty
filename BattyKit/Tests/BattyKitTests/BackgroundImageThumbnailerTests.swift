// BackgroundImageThumbnailerTests.swift

import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import BattyKit

nonisolated private final class Counter: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func increment() { value.withLock { $0 += 1 } }
}

@MainActor
struct BackgroundImageThumbnailerTests {
    private let f: ProjectBackgroundFixture

    init() throws { f = try ProjectBackgroundFixture() }

    private func thumbnailer(counting counter: Counter) -> BackgroundImageThumbnailer {
        BackgroundImageThumbnailer(decode: { url in
            counter.increment()
            return BackgroundImageThumbnailer.downsample(url)
        })
    }

    private func entry(_ data: Data) throws -> BackgroundImageEntry {
        let digest = BackgroundTestImage.digest(of: data)
        let folder = f.libraryFolder.appendingPathComponent(digest, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("photo.png")
        try data.write(to: file)
        return BackgroundImageEntry(digest: digest, path: file.path, name: "photo", sizeInBytes: Int64(data.count), addedAt: Date())
    }

    @Test func thumbnailIsDownsampledAndKeepsItsAspect() async throws {
        let picture = try entry(try BackgroundTestImage.encoded(width: 1600, height: 800))
        let result = await BackgroundImageThumbnailer().thumbnail(for: picture)
        let image = try #require(result.image)
        #expect(result.state == .usable)
        #expect(image.width == BackgroundImageThumbnailer.maxThumbnailPixelSize)
        #expect(image.height == BackgroundImageThumbnailer.maxThumbnailPixelSize / 2)
    }

    @Test func oversizedImageIsRejectedWithoutADecode() async throws {
        let counter = Counter()
        let picture = try entry(try BackgroundTestImage.encoded(width: 4097, height: 4))
        let result = await thumbnailer(counting: counter).thumbnail(for: picture)
        #expect(result.state == .rejected)
        #expect(result.image == nil)
        #expect(counter.count == 0)
    }

    @Test func damagedFileIsRejectedWithoutADecode() async throws {
        let counter = Counter()
        let picture = try entry(try BackgroundTestImage.encoded(width: 64))
        try BackgroundTestImage.encoded(width: 72).write(to: URL(fileURLWithPath: picture.path))
        let result = await thumbnailer(counting: counter).thumbnail(for: picture)
        #expect(result.state == .rejected)
        #expect(counter.count == 0)
    }

    @Test func missingFileIsMissing() async throws {
        let picture = try entry(try BackgroundTestImage.encoded(width: 64))
        try FileManager.default.removeItem(atPath: picture.path)
        #expect(await BackgroundImageThumbnailer().thumbnail(for: picture).state == .missing)
    }

    @Test func aDigestIsDecodedOnce() async throws {
        let counter = Counter()
        let picture = try entry(try BackgroundTestImage.encoded(width: 64))
        let thumbnailer = thumbnailer(counting: counter)
        _ = await thumbnailer.thumbnail(for: picture)
        let second = await thumbnailer.thumbnail(for: picture)
        #expect(second.image != nil)
        #expect(counter.count == 1)
    }
}
