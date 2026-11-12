// DownloadedImageCacheTests.swift

import Foundation
import Testing
@testable import BattyKit

/// A clock the test moves by hand.
nonisolated final class ManualNow: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var date: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval = 60) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

struct DownloadedImageCacheTests {
    private let base = FileManager.default.temporaryDirectory.appendingPathComponent("batty-downloaded-\(UUID().uuidString)", isDirectory: true)
    private let fetcher = FakeBackgroundCatalogFetcher()
    private let clock = ManualNow()

    private var directory: URL { base.appendingPathComponent("Downloaded", isDirectory: true) }

    private func cache(_ limits: DownloadedImageCache.Limits = .standard) -> DownloadedImageCache {
        let clock = clock
        return DownloadedImageCache(
            directory: directory, fetcher: fetcher,
            temporaryRoot: base.appendingPathComponent("tmp", isDirectory: true),
            limits: limits, now: { clock.date })
    }

    private func image(_ width: Int) throws -> (bytes: Data, digest: String) {
        let bytes = try BackgroundTestImage.encoded(width: width, height: 64)
        return (bytes, BackgroundTestImage.digest(of: bytes))
    }

    @discardableResult
    private func insert(_ cache: DownloadedImageCache, _ width: Int, pinned: Set<String> = []) async throws -> (digest: String, insertion: DownloadedImageCache.Insertion) {
        let (bytes, digest) = try image(width)
        clock.advance()
        let insertion = try #require(await cache.insertVerified(bytes: bytes, digest: digest, name: "w\(width)", pinned: pinned))
        return (digest, insertion)
    }

    private func held(_ cache: DownloadedImageCache) async -> [String] {
        await cache.allEntries().map(\.digest)
    }

    @Test func defaultLimitsAreTwentyImagesAndFiveHundredMegabytes() {
        #expect(DownloadedImageCache.Limits.standard == .init(count: 20, bytes: 500_000_000))
        #expect(cache().limits == .standard)
    }

    @Test func evictsLeastRecentlyUsedFirst() async throws {
        let cache = cache(.init(count: 2, bytes: .max))
        let a = try await insert(cache, 64)
        let b = try await insert(cache, 72)
        let c = try await insert(cache, 80)
        #expect(await held(cache) == [b.digest, c.digest])
        #expect(!FileManager.default.fileExists(atPath: a.insertion.path))
    }

    @Test func evictsByCountAboveTheLimit() async throws {
        let cache = cache(.init(count: 3, bytes: .max))
        for width in [64, 72, 80, 88, 96] { try await insert(cache, width) }
        #expect(await held(cache).count == 3)
    }

    @Test func evictsByBytesAboveTheLimit() async throws {
        let sizes = try [64, 72, 80].map { Int64(try image($0).bytes.count) }
        let cache = cache(.init(count: 20, bytes: sizes[1] + sizes[2] + 1))
        let a = try await insert(cache, 64)
        try await insert(cache, 72)
        try await insert(cache, 80)
        #expect(await held(cache).count == 2)
        #expect(!(await held(cache)).contains(a.digest))
    }

    @Test func neverEvictsAPinnedImage() async throws {
        let cache = cache(.init(count: 2, bytes: .max))
        let a = try await insert(cache, 64)
        let b = try await insert(cache, 72)
        try await insert(cache, 80, pinned: [a.digest])
        #expect(await held(cache).contains(a.digest))
        #expect(!(await held(cache)).contains(b.digest))
    }

    @Test func pinnedImagesMayExceedTheBoundsUntilTheNextInsert() async throws {
        let cache = cache(.init(count: 1, bytes: .max))
        let a = try await insert(cache, 64)
        let b = try await insert(cache, 72, pinned: [a.digest])
        #expect(await held(cache).count == 2)
        let c = try await insert(cache, 80)
        #expect(await held(cache) == [c.digest])
        #expect(b.insertion.evicted.isEmpty)
    }

    @Test func touchMovesAnImageToMostRecentlyUsed() async throws {
        let cache = cache(.init(count: 2, bytes: .max))
        let a = try await insert(cache, 64)
        let b = try await insert(cache, 72)
        clock.advance()
        await cache.touch(digest: a.digest)
        try await insert(cache, 80)
        #expect(await held(cache).contains(a.digest))
        #expect(!(await held(cache)).contains(b.digest))
    }

    @Test func insertOfAHeldDigestTouchesInsteadOfDuplicating() async throws {
        let cache = cache()
        let a = try await insert(cache, 64)
        let before = try #require(await cache.allEntries().first?.lastUsedAt)
        let again = try await insert(cache, 64)
        #expect(await held(cache) == [a.digest])
        #expect(again.insertion.path == a.insertion.path)
        #expect(try #require(await cache.allEntries().first?.lastUsedAt) > before)
    }

    @Test func indexSurvivesARelaunch() async throws {
        let first = cache()
        let a = try await insert(first, 64)
        let entries = await first.allEntries()
        let second = cache()
        #expect(await second.allEntries() == entries)
        #expect(await second.path(forDigest: a.digest) == a.insertion.path)
        let text = try String(contentsOf: directory.appendingPathComponent("downloaded-images.json"), encoding: .utf8)
        #expect(text.contains("\"version\":1"))
    }

    @Test func unreadableIndexKeepsFilesAndEvictsThemFirst() async throws {
        let first = cache(.init(count: 2, bytes: .max))
        let a = try await insert(first, 64)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("downloaded-images.json"))
        let second = cache(.init(count: 2, bytes: .max))
        #expect(await second.allEntries().first?.lastUsedAt == .distantPast)
        try await insert(second, 72)
        try await insert(second, 80)
        #expect(!(await held(second)).contains(a.digest))
    }

    @Test func entryWhoseFolderIsGoneIsDropped() async throws {
        let first = cache()
        let a = try await insert(first, 64)
        try FileManager.default.removeItem(at: directory.appendingPathComponent(a.digest, isDirectory: true))
        #expect(await cache().allEntries().isEmpty)
    }

    @Test func fetchHostedRefusesAHostNoCatalogNames() async throws {
        let url = URL(string: "https://example.com/a.png")!
        fetcher.set(.ok(try image(64).bytes), for: url)
        await #expect(throws: HostedImageError.disallowedHost) {
            try await cache().fetchHosted(url: url, name: "A", allowedHosts: ["batty.sstools.co"], pinned: [])
        }
        #expect(fetcher.requests.isEmpty)
    }

    @Test func fetchHostedRecordsTheURLInTheEntry() async throws {
        let url = URL(string: "https://batty.sstools.co/backgrounds/canal.png")!
        fetcher.set(.ok(try image(64).bytes), for: url)
        let cache = cache()
        let insertion = try await cache.fetchHosted(url: url, name: "Canal", allowedHosts: ["batty.sstools.co"], pinned: [])
        #expect(insertion.path.hasPrefix(directory.path))
        #expect(await cache.allEntries().first?.url == url)
        #expect(await cache.path(forURL: url) == insertion.path)
        _ = try await cache.fetchHosted(url: url, name: "Canal", allowedHosts: ["batty.sstools.co"], pinned: [])
        #expect(fetcher.count(url) == 1)
    }

    @Test func evictionReturnsThePathsItRemoved() async throws {
        let cache = cache(.init(count: 1, bytes: .max))
        let a = try await insert(cache, 64)
        let b = try await insert(cache, 72)
        #expect(b.insertion.evicted == [a.insertion.path])
    }
}
