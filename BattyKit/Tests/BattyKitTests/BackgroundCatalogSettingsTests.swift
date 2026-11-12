// BackgroundCatalogSettingsTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Serves catalogs of real PNGs through the fixture's fake fetcher.
@MainActor
struct HostedCatalogServer {
    let fetcher: FakeBackgroundCatalogFetcher

    func url(_ catalogURL: URL, _ name: String) -> URL {
        URL(string: name, relativeTo: catalogURL)!.absoluteURL
    }

    @discardableResult
    func serve(_ catalogURL: URL, ids: [String] = ["one", "two"], etag: String? = "\"c1\"", lastModified: String? = nil) throws -> Data {
        var images: [[String: Any]] = []
        for (index, id) in ids.enumerated() {
            fetcher.set(.ok(try BackgroundTestImage.encoded(width: 64 + index, height: 48)), for: url(catalogURL, "\(id).png"))
            fetcher.set(.ok(try BackgroundTestImage.encoded(width: 32, height: 24)), for: url(catalogURL, "\(id)-thumb.png"))
            images.append(["title": "Picture \(id)", "full": "\(id).png", "thumbnail": "\(id)-thumb.png"])
        }
        let body = CatalogJSON.data(["sets": [["name": "Set \(catalogURL.host ?? "")", "images": images]]])
        fetcher.set(.ok(body, etag: etag, lastModified: lastModified), for: catalogURL)
        return body
    }
}

@MainActor
struct BackgroundCatalogSettingsTests {
    private let f: ProjectBackgroundFixture
    private let store: AppStateStore
    private var hosted: HostedBackgroundsModel { store.backgroundImages.hosted }
    private var fetcher: FakeBackgroundCatalogFetcher { f.catalogFetcher }
    private var defaults: UserDefaults { f.testDefaults.defaults }
    private var server: HostedCatalogServer { HostedCatalogServer(fetcher: fetcher) }
    private let builtIn = BackgroundCatalog.builtInURL
    private let userURL = URL(string: "https://catalogs.example.com/catalog.json")!
    private let otherURL = URL(string: "https://other.example.com/sets/catalog.json")!

    init() throws {
        f = try ProjectBackgroundFixture()
        store = f.appStore()
    }

    private var storedURLs: [String]? {
        defaults.array(forKey: SettingsPreference.backgroundCatalogURLsKey) as? [String]
    }

    private func add(_ text: String) async -> BackgroundCatalogURLRefusal? {
        if case .failure(let refusal) = await hosted.addCatalog(text) { return refusal }
        return nil
    }

    private func cacheFolderExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: hosted.cache.folder(for: url).path)
    }

    @Test func addingAValidCatalogSavesItAndListsItAfterTheBuiltIn() async throws {
        try server.serve(userURL)
        #expect(await hosted.addCatalog(userURL.absoluteString) == .success(userURL))
        #expect(storedURLs == [userURL.absoluteString])
        #expect(hosted.catalogRows.map(\.url) == [builtIn, userURL])
        #expect(hosted.catalogRows.last?.catalog?.allImages.count == 2)
        #expect(hosted.catalogRows.last?.lastChecked == f.clock.now)
        #expect(await hosted.cache.cachedCatalog(for: userURL) != nil)
        #expect(!hosted.isAddingCatalog)
    }

    @Test func addingRefusesNonHTTPSAndWritesNothing() async throws {
        #expect(await add("http://example.com/catalog.json") == .notHTTPS)
        #expect(storedURLs == nil)
        #expect(fetcher.requests.isEmpty)
    }

    @Test func addingADuplicateAfterNormalizationIsRefused() async throws {
        try server.serve(userURL)
        _ = await hosted.addCatalog(userURL.absoluteString)
        #expect(await add("HTTPS://Catalogs.Example.com:443/catalog.json#x") == .duplicate)
        #expect(fetcher.count(userURL) == 1)
        #expect(storedURLs == [userURL.absoluteString])
    }

    @Test func addingTheBuiltInURLIsRefusedAsADuplicate() async throws {
        #expect(await add(builtIn.absoluteString) == .duplicate)
        #expect(fetcher.requests.isEmpty)
        #expect(storedURLs == nil)
    }

    @Test func theTwentyFirstURLIsRefused() async throws {
        let twenty = (1...20).map { URL(string: "https://host\($0).example.com/catalog.json")! }
        SettingsPreference.setBackgroundCatalogURLs(twenty, defaults: defaults)
        let seeded = f.appStore()
        try server.serve(userURL)
        let result = await seeded.backgroundImages.hosted.addCatalog(userURL.absoluteString)
        #expect(result == .failure(.tooMany))
        #expect(BackgroundCatalogURLRefusal.tooMany.message == "You can add up to 20 catalogs")
        #expect(fetcher.requests.isEmpty)
        #expect(storedURLs == twenty.map(\.absoluteString))
    }

    @Test(arguments: [true, false])
    func aCatalogOverOneMegabyteIsRefused(fetcherRefuses: Bool) async throws {
        if fetcherRefuses {
            fetcher.set(.failure(.tooLarge), for: userURL)
            #expect(await add(userURL.absoluteString) == .fetch("File is larger than allowed"))
        } else {
            let padding = String(repeating: " ", count: BackgroundCatalogLimits.catalogBytes + 1)
            let fake = OverLimitBodyFetcher(body: Data(("{\"sets\":[]}" + padding).utf8))
            let local = ProjectBackgroundFixture.hostedModel(fixture: f, fetcher: fake)
            let result = await local.addCatalog(userURL.absoluteString)
            #expect(result == .failure(.fetch("Catalog is larger than 1 MB")))
        }
        #expect(storedURLs == nil)
    }

    @Test func anInvalidCatalogIsRefusedWithItsFirstBadPath() async throws {
        fetcher.set(.ok(Data("<html><body>Hello</body></html>".utf8)), for: userURL)
        #expect(await add(userURL.absoluteString) == .fetch("Not a background catalog: (root)"))
        #expect(storedURLs == nil)
        #expect(!cacheFolderExists(userURL))
    }

    @Test func aCatalogWithAnUntitledImageIsRefusedNamingTheTitlePath() async throws {
        let body = CatalogJSON.data(["sets": [["name": "Set", "images": [
            ["title": "First", "full": "one.png", "thumbnail": "one-thumb.png"],
            ["full": "two.png", "thumbnail": "two-thumb.png"],
        ]]]])
        fetcher.set(.ok(body), for: userURL)
        #expect(await add(userURL.absoluteString) == .fetch("Not a background catalog: sets[0].images[1].title"))
        #expect(storedURLs == nil)
        #expect(!cacheFolderExists(userURL))
    }

    @Test func anUnreachableURLIsRefusedAndNothingIsSaved() async throws {
        fetcher.set(.failure(.unreachable), for: userURL)
        #expect(await add(userURL.absoluteString) == .fetch("Can't reach catalogs.example.com"))
        #expect(storedURLs == nil)
        #expect(hosted.catalogRows.map(\.url) == [builtIn])
        #expect(!cacheFolderExists(userURL))
    }

    @Test func addingBeforeBrowseFetchesOnlyThatURLAndLeavesBrowsedUnset() async throws {
        try server.serve(builtIn)
        try server.serve(userURL)
        _ = await hosted.addCatalog(userURL.absoluteString)
        #expect(fetcher.requestedURLs == [userURL])
        #expect(!hosted.hasBrowsed)
    }

    @Test func theBuiltInCatalogCannotBeCheckedBeforeTheFirstBrowse() async throws {
        try server.serve(builtIn)
        try server.serve(userURL)
        _ = await hosted.addCatalog(userURL.absoluteString)
        let rows = hosted.catalogRows
        #expect(!hosted.canCheckNow(rows[0]))
        #expect(hosted.canCheckNow(rows[1]))
        await hosted.refresh(builtIn)
        #expect(fetcher.requestedURLs == [userURL])
        #expect(!hosted.hasBrowsed)

        await hosted.browseAppeared()
        #expect(hosted.canCheckNow(hosted.catalogRows[0]))
        #expect(fetcher.requestedURLs.contains(builtIn))
    }

    @Test func userCatalogsAreListedInTheOrderAdded() async throws {
        try server.serve(otherURL)
        try server.serve(userURL)
        _ = await hosted.addCatalog(otherURL.absoluteString)
        _ = await hosted.addCatalog(userURL.absoluteString)
        #expect(hosted.userCatalogURLs == [otherURL, userURL])
        #expect(hosted.catalogRows.map(\.url) == [builtIn, otherURL, userURL])
        #expect(f.appStore().backgroundImages.hosted.userCatalogURLs == [otherURL, userURL])
    }

    @Test func browseShowsUserCatalogSetsAfterTheBuiltIn() async throws {
        try server.serve(builtIn)
        try server.serve(userURL)
        _ = await hosted.addCatalog(userURL.absoluteString)
        await hosted.browseAppeared()
        #expect(hosted.catalogs.map(\.url) == [builtIn, userURL])
        #expect(hosted.catalogs.allSatisfy { $0.catalog?.sets.isEmpty == false })
    }

    @Test func theBuiltInCatalogCannotBeRemoved() async throws {
        try server.serve(builtIn)
        await hosted.browseAppeared()
        await hosted.removeCatalog(builtIn)
        #expect(hosted.catalogRows.map(\.url) == [builtIn])
        #expect(hosted.catalogs.first?.catalog != nil)
        #expect(cacheFolderExists(builtIn))
    }

    @Test func removingDropsTheURLItsCacheFolderAndItsRecords() async throws {
        try server.serve(userURL)
        _ = await hosted.addCatalog(userURL.absoluteString)
        let image = try #require(hosted.catalogRows.last?.catalog?.allImages.first)
        let path = try #require(await hosted.select(image).value)
        #expect(await hosted.store.records().map(\.url) == [image.full])
        await hosted.removeCatalog(userURL)
        #expect(hosted.userCatalogURLs.isEmpty)
        #expect(storedURLs == [])
        #expect(!cacheFolderExists(userURL))
        #expect(await hosted.store.records().isEmpty)
        #expect(hosted.catalogRows.map(\.url) == [builtIn])
        #expect(!hosted.catalogs.contains { $0.url == userURL })
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func removingKeepsTheHostedCopyAndAnAppWideUseOfItsImage() async throws {
        try server.serve(userURL)
        _ = await hosted.addCatalog(userURL.absoluteString)
        let image = try #require(hosted.catalogRows.last?.catalog?.allImages.first)
        let hostedPath = try #require(await hosted.select(image).value)
        let importer = TerminalBackgroundImageImporter(directory: f.appWideFolder, cleanup: .allButRetained)
        let adopted = try #require(await importer.adoptImage(path: hostedPath, from: store.backgroundImages.pickSources))
        let digest = try #require(TerminalBackgroundImageImporter.digest(ofPath: hostedPath))
        await hosted.removeCatalog(userURL)
        #expect(FileManager.default.fileExists(atPath: adopted))
        #expect(FileManager.default.fileExists(atPath: f.hostedFolder.appendingPathComponent(digest).path))
        await store.backgroundImages.refresh()
        #expect(!store.backgroundImages.entries.contains { $0.digest == digest })
    }

    @Test func removingKeepsRecordsForAnImageAnotherCatalogAlsoLists() async throws {
        try server.serve(userURL)
        let shared = server.url(userURL, "one.png")
        let otherBody = CatalogJSON.data(["sets": [["name": "Other", "images": [
            ["title": "Shared", "full": shared.absoluteString, "thumbnail": server.url(userURL, "one-thumb.png").absoluteString],
        ]]]])
        fetcher.set(.ok(otherBody), for: otherURL)
        _ = await hosted.addCatalog(userURL.absoluteString)
        _ = await hosted.addCatalog(otherURL.absoluteString)
        let images = try #require(hosted.catalogRows[1].catalog?.allImages)
        for image in images { _ = try #require(await hosted.select(image).value) }
        await hosted.removeCatalog(userURL)
        #expect(await hosted.store.records().map(\.url) == [shared])
    }

    @Test func reAddingARemovedCatalogShowsItsImagesAsNotAvailable() async throws {
        try server.serve(userURL)
        _ = await hosted.addCatalog(userURL.absoluteString)
        let image = try #require(hosted.catalogRows.last?.catalog?.allImages.first)
        _ = try #require(await hosted.select(image).value)
        #expect(hosted.available.contains(HostedImageKey(image)))
        await hosted.removeCatalog(userURL)
        #expect(await hosted.addCatalog(userURL.absoluteString) == .success(userURL))
        await hosted.reconcileAvailability()
        #expect(!hosted.available.contains(HostedImageKey(image)))
    }

    @Test func removingDuringARefreshLeavesNoCacheAndNoRow() async throws {
        try server.serve(userURL)
        _ = await hosted.addCatalog(userURL.absoluteString)
        await hosted.cache.removeAll(for: userURL)
        let before = fetcher.requests.count
        fetcher.hold(userURL)
        let refresh = Task { await hosted.refresh(userURL) }
        #expect(await fetcher.waitForRequests(before + 1))
        let fetcher = fetcher
        hosted.onCatalogForgotten = { _ in fetcher.release(self.userURL) }
        await hosted.removeCatalog(userURL)
        await refresh.value
        #expect(!cacheFolderExists(userURL))
        #expect(!hosted.catalogs.contains { $0.url == userURL })
    }

    @Test func checkNowFetchesEvenWithAutomaticChecksOff() async throws {
        defaults.set(false, forKey: SettingsPreference.backgroundCatalogsAutoCheckKey)
        try server.serve(userURL)
        _ = await hosted.addCatalog(userURL.absoluteString)
        await hosted.refresh(userURL)
        #expect(fetcher.count(userURL) == 2)
    }

    @Test func loadingRowsReadsCachesWithoutARequest() async throws {
        try server.serve(userURL)
        _ = await hosted.addCatalog(userURL.absoluteString)
        let before = fetcher.requests.count
        let fresh = f.appStore().backgroundImages.hosted
        await fresh.loadCatalogRows()
        #expect(fetcher.requests.count == before)
        #expect(fresh.catalogRows.map(\.url) == [builtIn, userURL])
        #expect(fresh.catalogRows.last?.catalog?.allImages.count == 2)
        #expect(fresh.catalogRows.last?.lastChecked == f.clock.now)
    }
}

/// Returns `body` whatever the byte limit, standing in for a server whose
/// stream the transport didn't stop.
nonisolated struct OverLimitBodyFetcher: BackgroundCatalogFetching {
    let body: Data

    func fetch(_ request: HostedFetchRequest, progress: (@Sendable (Int64) -> Void)?) async throws(HostedFetchError) -> HostedFetchResponse {
        HostedFetchResponse(status: 200, body: body, etag: nil, lastModified: nil, expectedLength: nil)
    }
}

extension ProjectBackgroundFixture {
    static func hostedModel(fixture f: ProjectBackgroundFixture, fetcher: BackgroundCatalogFetching) -> HostedBackgroundsModel {
        HostedBackgroundsModel(
            imageDirectory: f.hostedFolder,
            dependencies: HostedBackgroundsDependencies(
                fetcher: fetcher,
                cacheRoot: f.base.appendingPathComponent("BackgroundCatalogs-\(UUID().uuidString)", isDirectory: true),
                temporaryRoot: f.base.appendingPathComponent("downloads", isDirectory: true),
                clock: f.clock
            ),
            defaults: f.testDefaults.defaults
        )
    }
}
