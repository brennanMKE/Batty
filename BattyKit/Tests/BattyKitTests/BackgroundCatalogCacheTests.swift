// BackgroundCatalogCacheTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct BackgroundCatalogCacheTests {
    private let f = HostedImageFixture()

    @Test func storedCatalogReloadsWithItsValidators() async throws {
        let body = CatalogJSON.data(CatalogJSON.catalog())
        let checked = Date(timeIntervalSince1970: 1_000_000)
        await f.cache.store(body: body, validators: HostedValidators(etag: "\"v1\"", lastModified: "Tue"), for: f.catalogURL, at: checked)
        let cached = try #require(await f.cache.cachedCatalog(for: f.catalogURL))
        #expect(cached.catalog.allImages.count == 2)
        #expect(cached.state.etag == "\"v1\"")
        #expect(cached.state.lastModified == "Tue")
        #expect(cached.state.lastChecked == checked)
        #expect(await f.cache.cachedCatalog(for: URL(string: "https://example.com/c.json")!) == nil)
    }

    @Test func storedBodyThatNoLongerParsesIsIgnored() async throws {
        await f.cache.store(body: Data("{}".utf8), validators: HostedValidators(), for: f.catalogURL, at: Date())
        #expect(await f.cache.cachedCatalog(for: f.catalogURL) == nil)
    }

    @Test func thumbnailRoundTripsWithItsMetadata() async throws {
        let data = try BackgroundTestImage.encoded(width: 32, height: 32)
        let full = f.url("a.png")
        let metadata = CachedThumbnailMetadata(url: f.url("a-thumb.png"), etag: "\"e\"", lastModified: nil)
        let stored = try #require(await f.cache.storeThumbnail(data, metadata: metadata, for: f.catalogURL, image: full))
        let cached = try #require(await f.cache.thumbnail(for: f.catalogURL, image: full))
        #expect(cached.file == stored)
        #expect(cached.metadata == metadata)
        #expect(try Data(contentsOf: cached.file) == data)
        #expect(stored.deletingLastPathComponent().lastPathComponent == "thumbnails")
        #expect(await f.cache.thumbnail(for: f.catalogURL, image: f.url("b.png")) == nil)
    }

    @Test func removeAllDeletesTheCatalogsFolder() async throws {
        await f.cache.store(body: CatalogJSON.data(CatalogJSON.catalog()), validators: HostedValidators(), for: f.catalogURL, at: Date())
        await f.cache.removeAll(for: f.catalogURL)
        #expect(!FileManager.default.fileExists(atPath: f.cache.folder(for: f.catalogURL).path))
        #expect(await f.cache.cachedCatalog(for: f.catalogURL) == nil)
    }
}
