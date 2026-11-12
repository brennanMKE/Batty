// HostedThumbnailLoaderTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct HostedThumbnailLoaderTests {
    private let f = HostedImageFixture()

    private func loader() -> HostedThumbnailLoader {
        HostedThumbnailLoader(fetcher: f.fetcher, cache: f.cache)
    }

    private func thumbnailImage(id: String = "harbor-01", thumbnail: Data) throws -> HostedBackgroundImage {
        f.image(id: id, data: try BackgroundTestImage.encoded(width: 16, height: 16), thumbnail: thumbnail)
    }

    @Test func thumbnailIsFetchedOnceThenServedFromMemory() async throws {
        let image = try thumbnailImage(thumbnail: try BackgroundTestImage.encoded(width: 64, height: 40))
        let loader = loader()
        let first = await loader.thumbnail(for: image, catalogURL: f.catalogURL)
        #expect(first.state == .usable)
        #expect(first.image?.width == 64)
        let second = await loader.thumbnail(for: image, catalogURL: f.catalogURL)
        #expect(second.state == .usable)
        #expect(f.fetcher.count(image.thumbnail) == 1)
    }

    @Test func aChangedPictureAtTheSameURLIsPickedUpOnRevalidation() async throws {
        let image = try thumbnailImage(thumbnail: try BackgroundTestImage.encoded(width: 64, height: 40))
        _ = await loader().thumbnail(for: image, catalogURL: f.catalogURL)
        let changed = try thumbnailImage(thumbnail: try BackgroundTestImage.encoded(width: 48, height: 40))
        let result = await loader().thumbnail(for: changed, catalogURL: f.catalogURL)
        #expect(result.image?.width == 48)
        #expect(f.fetcher.count(image.thumbnail) == 2)
    }

    @Test func notModifiedReusesTheCachedFile() async throws {
        let image = try thumbnailImage(thumbnail: try BackgroundTestImage.encoded(width: 64, height: 40))
        _ = await loader().thumbnail(for: image, catalogURL: f.catalogURL)
        f.fetcher.set(.notModified, for: image.thumbnail)
        let result = await loader().thumbnail(for: image, catalogURL: f.catalogURL)
        #expect(result.state == .usable)
        #expect(result.image?.width == 64)
        #expect(f.fetcher.requests.last?.etag == "\"t-harbor-01\"")
    }

    @Test func thumbnailOverTheSizeLimitIsRejected() async throws {
        let big = BackgroundCatalogLimits.thumbnailPixels + 1
        let image = try thumbnailImage(thumbnail: try BackgroundTestImage.encoded(width: big, height: 16))
        #expect(await loader().thumbnail(for: image, catalogURL: f.catalogURL).state == .rejected)
    }

    @Test func thumbnailWhoseTypeDoesNotMatchItsExtensionIsRejected() async throws {
        let image = try thumbnailImage(thumbnail: try BackgroundTestImage.encoded(width: 64, height: 40, type: .jpeg))
        #expect(await loader().thumbnail(for: image, catalogURL: f.catalogURL).state == .rejected)
    }

    @Test func thumbnailOverTwoMegabytesIsRejected() async throws {
        let image = try thumbnailImage(thumbnail: Data(count: Int(BackgroundCatalogLimits.thumbnailBytes) + 1))
        #expect(await loader().thumbnail(for: image, catalogURL: f.catalogURL).state == .rejected)
        #expect(f.fetcher.requests.last?.byteLimit == BackgroundCatalogLimits.thumbnailBytes)
    }

    @Test func deletedCacheMeansARefetch() async throws {
        let image = try thumbnailImage(thumbnail: try BackgroundTestImage.encoded(width: 64, height: 40))
        _ = await loader().thumbnail(for: image, catalogURL: f.catalogURL)
        try FileManager.default.removeItem(at: f.cacheRoot)
        #expect(await loader().thumbnail(for: image, catalogURL: f.catalogURL).state == .usable)
        #expect(f.fetcher.count(image.thumbnail) == 2)
    }

    @Test func unreachableWithACachedFileUsesIt() async throws {
        let image = try thumbnailImage(thumbnail: try BackgroundTestImage.encoded(width: 64, height: 40))
        _ = await loader().thumbnail(for: image, catalogURL: f.catalogURL)
        f.fetcher.set(.failure(.unreachable), for: image.thumbnail)
        #expect(await loader().thumbnail(for: image, catalogURL: f.catalogURL).state == .usable)
        #expect(f.fetcher.count(image.thumbnail) == 2)
    }

    @Test func thumbnailNeverEntersTheLibraryOrTheHostedStore() async throws {
        let image = try thumbnailImage(thumbnail: try BackgroundTestImage.encoded(width: 64, height: 40))
        _ = await loader().thumbnail(for: image, catalogURL: f.catalogURL)
        #expect(!FileManager.default.fileExists(atPath: f.hostedFolder.deletingLastPathComponent().path))
        #expect(await f.store.records().isEmpty)
        #expect(f.fetcher.count(image.full) == 0)
    }
}
