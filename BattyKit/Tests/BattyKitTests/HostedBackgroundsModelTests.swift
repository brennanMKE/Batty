// HostedBackgroundsModelTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct HostedBackgroundsModelTests {
    private let f: ProjectBackgroundFixture
    private let store: AppStateStore
    private var hosted: HostedBackgroundsModel { store.backgroundImages.hosted }
    private var fetcher: FakeBackgroundCatalogFetcher { f.catalogFetcher }
    private let catalogURL = BackgroundCatalog.builtInURL

    init() throws {
        f = try ProjectBackgroundFixture()
        store = f.appStore()
    }

    private func url(_ name: String) -> URL {
        URL(string: "https://batty.sstools.co/backgrounds/\(name)")!
    }

    /// Serves a catalog of `ids` with real full-size PNGs and thumbnails.
    @discardableResult
    private func serveCatalog(_ ids: [String] = ["one", "two"], etag: String? = "\"c1\"") throws -> Data {
        var images: [[String: Any]] = []
        for (index, id) in ids.enumerated() {
            let full = try BackgroundTestImage.encoded(width: 64 + index, height: 48)
            let thumb = try BackgroundTestImage.encoded(width: 32, height: 24)
            fetcher.set(.ok(full), for: url("\(id).png"))
            fetcher.set(.ok(thumb), for: url("\(id)-thumb.png"))
            images.append(["title": "Picture \(id)", "full": "\(id).png", "thumbnail": "\(id)-thumb.png"])
        }
        let body = CatalogJSON.data(["sets": [["name": "Set", "images": images]]])
        fetcher.set(.ok(body, etag: etag), for: catalogURL)
        return body
    }

    private func image(_ id: String) throws -> HostedBackgroundImage {
        try #require(hosted.catalogs.first?.catalog?.allImages.first { $0.full == url("\(id).png") })
    }

    @Test func nothingIsFetchedBeforeBrowseAppears() async throws {
        try serveCatalog()
        await store.backgroundImages.refresh()
        #expect(fetcher.requests.isEmpty)
        #expect(!hosted.hasBrowsed)
    }

    @Test func browseAppearingSetsTheBrowsedFlag() async throws {
        try serveCatalog()
        await hosted.browseAppeared()
        #expect(hosted.hasBrowsed)
        #expect(f.testDefaults.defaults.bool(forKey: SettingsPreference.backgroundCatalogsBrowsedKey))
    }

    @Test func browsingFetchesNoFullSizeFile() async throws {
        try serveCatalog()
        await hosted.browseAppeared()
        for image in try #require(hosted.catalogs.first?.catalog).allImages {
            _ = await hosted.thumbnail(for: image, catalogURL: catalogURL)
        }
        #expect(Set(fetcher.requestedURLs) == [catalogURL, url("one-thumb.png"), url("two-thumb.png")])
    }

    @Test func firstBrowseFetchesTheCatalogAndCachesItWithValidators() async throws {
        try serveCatalog()
        await hosted.browseAppeared()
        #expect(hosted.catalogs.first?.catalog?.allImages.count == 2)
        #expect(hosted.catalogs.first?.problem == nil)
        let cached = try #require(await hosted.cache.cachedCatalog(for: catalogURL))
        #expect(cached.state.etag == "\"c1\"")
    }

    @Test func notModifiedKeepsTheCachedCatalogAndSendsItsValidators() async throws {
        try serveCatalog()
        await hosted.browseAppeared()
        fetcher.set(.notModified, for: catalogURL)
        await hosted.refresh(catalogURL)
        #expect(fetcher.requests.last?.etag == "\"c1\"")
        #expect(hosted.catalogs.first?.catalog?.allImages.count == 2)
        #expect(hosted.catalogs.first?.problem == nil)
    }

    @Test func badNewBodyKeepsTheOldCopyAndShowsTheError() async throws {
        try serveCatalog()
        await hosted.browseAppeared()
        fetcher.set(.ok(Data("<html>".utf8)), for: catalogURL)
        await hosted.refresh(catalogURL)
        #expect(hosted.catalogs.first?.catalog?.allImages.count == 2)
        #expect(hosted.catalogs.first?.problem == .invalid("Not a background catalog: (root)"))
        #expect(await hosted.cache.cachedCatalog(for: catalogURL)?.catalog.allImages.count == 2)
    }

    @Test func browseRefreshesAtMostOncePerTenMinutes() async throws {
        try serveCatalog()
        await hosted.browseAppeared()
        #expect(fetcher.count(catalogURL) == 1)
        _ = await f.clock.advance(by: .seconds(5 * 60))
        await hosted.browseAppeared()
        #expect(fetcher.count(catalogURL) == 1)
        _ = await f.clock.advance(by: .seconds(6 * 60))
        await hosted.browseAppeared()
        #expect(fetcher.count(catalogURL) == 2)
    }

    @Test func offlineWithACacheShowsTheLastCopyBanner() async throws {
        try serveCatalog()
        await hosted.browseAppeared()
        fetcher.set(.failure(.unreachable), for: catalogURL)
        await hosted.refresh(catalogURL)
        #expect(hosted.catalogs.first?.problem == .offlineShowingCache("batty.sstools.co"))
        #expect(hosted.catalogs.first?.catalog != nil)
    }

    @Test func offlineWithNoCacheShowsTheRetryBanner() async throws {
        fetcher.set(.failure(.unreachable), for: catalogURL)
        await hosted.browseAppeared()
        #expect(hosted.catalogs.first?.problem == .offlineNoCache("batty.sstools.co"))
        #expect(hosted.catalogs.first?.catalog == nil)
    }

    @Test func selectingFetchesOnceShowsProgressAndMakesItAvailable() async throws {
        try serveCatalog()
        await hosted.browseAppeared()
        let one = try image("one")
        let key = HostedImageKey(url: url("one.png"))
        let before = fetcher.requests.count
        fetcher.hold(one.full)
        let task = hosted.select(one)
        #expect(await fetcher.waitForRequests(before + 1))
        if case .fetching = hosted.fetches[key] {} else { Issue.record("expected .fetching, got \(String(describing: hosted.fetches[key]))") }
        fetcher.release(one.full)
        let path = try #require(await task.value)
        #expect(path.hasPrefix(f.hostedFolder.path))
        #expect(hosted.available.contains(key))
        #expect(hosted.fetches[key] == nil)
        #expect(await hosted.select(one).value == path)
        #expect(fetcher.count(one.full) == 1)
    }

    @Test func selectingOfflineAfterAFetchStillReturnsThePath() async throws {
        try serveCatalog()
        await hosted.browseAppeared()
        let one = try image("one")
        let path = await hosted.select(one).value
        fetcher.set(.failure(.unreachable), for: one.full)
        #expect(path != nil)
        #expect(await hosted.select(one).value == path)
    }

    @Test func failedSelectShowsTheReasonAndReturnsNil() async throws {
        try serveCatalog()
        await hosted.browseAppeared()
        let one = try image("one")
        fetcher.set(.failure(.notFound), for: one.full)
        #expect(await hosted.select(one).value == nil)
        #expect(hosted.fetches[HostedImageKey(url: url("one.png"))] == .failed("Not found (404)"))
    }

    @Test func cancelledSelectClearsTheStateAndKeepsNothing() async throws {
        try serveCatalog()
        await hosted.browseAppeared()
        let one = try image("one")
        let key = HostedImageKey(url: url("one.png"))
        let before = fetcher.requests.count
        fetcher.hold(one.full)
        let task = hosted.select(one)
        #expect(await fetcher.waitForRequests(before + 1))
        hosted.cancelFetch(key)
        fetcher.release(one.full)
        #expect(await task.value == nil)
        #expect(hosted.fetches[key] == nil)
        #expect(!hosted.available.contains(key))
        #expect(await hosted.store.records().isEmpty)
    }

    @Test func atMostTwoFullSizeFetchesRunAtOnce() async throws {
        try serveCatalog(["one", "two", "three"])
        await hosted.browseAppeared()
        let images = try ["one", "two", "three"].map(image)
        let before = fetcher.requests.count
        for image in images { fetcher.hold(image.full) }
        let tasks = images.map { hosted.select($0) }
        #expect(await fetcher.waitForRequests(before + 2))
        #expect(fetcher.count(images[0].full) + fetcher.count(images[1].full) + fetcher.count(images[2].full) == 2)
        for image in images { fetcher.release(image.full) }
        for task in tasks { #expect(await task.value != nil) }
        #expect(hosted.available.count == 3)
    }

    @Test func cancellingAQueuedFetchLeavesTheQueueAndClearsItsCell() async throws {
        try serveCatalog(["one", "two", "three"])
        await hosted.browseAppeared()
        let images = try ["one", "two", "three"].map(image)
        let third = HostedImageKey(url: url("three.png"))
        let before = fetcher.requests.count
        for image in images { fetcher.hold(image.full) }
        let running = images.prefix(2).map { hosted.select($0) }
        #expect(await fetcher.waitForRequests(before + 2))
        var queued: Task<String?, Never>?
        let didQueue = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            let timeout = DispatchWorkItem { once.resume(false) }
            once.setOnResumed { timeout.cancel() }
            hosted.onFetchQueued = { if $0 == third { once.resume(true) } }
            queued = hosted.select(images[2])
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + TestBounds.hangGuard, execute: timeout)
        }
        #expect(didQueue)
        let queuedTask = try #require(queued)
        #expect(hosted.fetches[third] == .fetching)
        hosted.cancelFetch(third)
        #expect(await queuedTask.value == nil)
        #expect(hosted.fetches[third] == nil)
        #expect(fetcher.count(images[2].full) == 0)
        for image in images { fetcher.release(image.full) }
        for task in running { #expect(await task.value != nil) }
        #expect(await hosted.select(images[2]).value != nil)
        #expect(hosted.available.count == 3)
    }

    @Test func aLaterHostedPickWinsOverAnEarlierOneThatFinishesAfterIt() async throws {
        try serveCatalog(["one", "two"])
        await hosted.browseAppeared()
        let one = try image("one"), two = try image("two")
        let keyOne = HostedImageKey(url: url("one.png"))
        var picked: [String] = []
        let before = fetcher.requests.count
        fetcher.hold(one.full)
        fetcher.hold(two.full)
        let first = hosted.pick(one) { picked.append($0) }
        #expect(await fetcher.waitForRequests(before + 1))
        let second = hosted.pick(two) { picked.append($0) }
        #expect(await fetcher.waitForRequests(before + 2))
        fetcher.release(two.full)
        await second.value
        #expect(picked.count == 1)
        fetcher.release(one.full)
        await first.value
        #expect(picked == [try #require(await hosted.select(two).value)])
        #expect(!hosted.available.contains(keyOne))
        #expect(hosted.fetches[keyOne] == nil)
    }

    @Test func aCachedHostedPickSupersedesAnEarlierDownload() async throws {
        try serveCatalog(["one", "two"])
        await hosted.browseAppeared()
        let one = try image("one"), two = try image("two")
        let cachedTwo = try #require(await hosted.select(two).value)
        var picked: [String] = []
        let before = fetcher.requests.count
        fetcher.hold(one.full)
        let first = hosted.pick(one) { picked.append($0) }
        #expect(await fetcher.waitForRequests(before + 1))
        await hosted.pick(two) { picked.append($0) }.value
        #expect(picked == [cachedTwo])
        fetcher.release(one.full)
        await first.value
        #expect(picked == [cachedTwo])
        #expect(!hosted.available.contains(HostedImageKey(url: url("one.png"))))
    }

    @Test func aMyImagesPickSupersedesAPendingHostedPick() async throws {
        try serveCatalog(["one"])
        await hosted.browseAppeared()
        let one = try image("one")
        var picked: [String] = []
        let before = fetcher.requests.count
        fetcher.hold(one.full)
        let pending = hosted.pick(one) { picked.append($0) }
        #expect(await fetcher.waitForRequests(before + 1))
        hosted.supersedePicks()
        fetcher.release(one.full)
        await pending.value
        #expect(picked.isEmpty)
        #expect(!hosted.available.contains(HostedImageKey(url: url("one.png"))))
        #expect(await hosted.store.records().isEmpty)
    }

    @Test func dismissingTheSheetWhileFetchingPicksNothing() async throws {
        try serveCatalog(["one"])
        await hosted.browseAppeared()
        let one = try image("one")
        var picked: [String] = []
        let before = fetcher.requests.count
        fetcher.hold(one.full)
        let pending = hosted.pick(one) { picked.append($0) }
        #expect(await fetcher.waitForRequests(before + 1))
        hosted.supersedePicks()
        fetcher.release(one.full)
        await pending.value
        #expect(picked.isEmpty)
        #expect(hosted.fetches[HostedImageKey(url: url("one.png"))] == nil)
    }

    @Test func repickingAnImageRightAfterItsFetchWasCancelledFetchesItAgain() async throws {
        try serveCatalog(["one", "two"])
        await hosted.browseAppeared()
        let one = try image("one"), two = try image("two")
        var picked: [String] = []
        let before = fetcher.requests.count
        fetcher.hold(one.full)
        fetcher.hold(two.full)
        let first = hosted.pick(one) { picked.append($0) }
        #expect(await fetcher.waitForRequests(before + 1))
        let second = hosted.pick(two) { picked.append($0) }
        #expect(await fetcher.waitForRequests(before + 2))
        let again = hosted.pick(one) { picked.append($0) }
        fetcher.release(one.full)
        fetcher.release(two.full)
        await first.value
        await second.value
        await again.value
        let path = try #require(await hosted.select(one).value)
        #expect(picked == [path])
        #expect(fetcher.count(one.full) == 2)
        #expect(hosted.fetches[HostedImageKey(url: url("one.png"))] == nil)
    }

    @Test func aPickJoiningAnotherFetchOfTheSameImageNeverCancelsIt() async throws {
        try serveCatalog(["one", "two"])
        await hosted.browseAppeared()
        let one = try image("one"), two = try image("two")
        var picked: [String] = []
        let before = fetcher.requests.count
        fetcher.hold(one.full)
        let elsewhere = hosted.select(one)
        #expect(await fetcher.waitForRequests(before + 1))
        let dismissed = hosted.pick(one) { picked.append($0) }
        hosted.supersedePicks()
        let joined = hosted.pick(one) { picked.append($0) }
        let other = hosted.pick(two) { picked.append($0) }
        await other.value
        fetcher.release(one.full)
        await dismissed.value
        await joined.value
        let path = try #require(await elsewhere.value)
        #expect(picked == [try #require(await hosted.select(two).value)])
        #expect(hosted.available.contains(HostedImageKey(url: url("one.png"))))
        #expect(await hosted.select(one).value == path)
        #expect(fetcher.count(one.full) == 1)
    }

    @Test func aPickOfADifferentImageStillCancelsTheFetchItStarted() async throws {
        try serveCatalog(["one", "two"])
        await hosted.browseAppeared()
        let one = try image("one"), two = try image("two")
        let before = fetcher.requests.count
        fetcher.hold(one.full)
        let first = hosted.pick(one) { _ in }
        let fetchOne = hosted.select(one)
        #expect(await fetcher.waitForRequests(before + 1))
        _ = hosted.pick(one) { _ in }
        await hosted.pick(two) { _ in }.value
        fetcher.release(one.full)
        await first.value
        #expect(await fetchOne.value == nil)
        #expect(!hosted.available.contains(HostedImageKey(url: url("one.png"))))
    }

    @Test func clickingTheDownloadingPickAgainCancelsItAndPicksNothing() async throws {
        try serveCatalog(["one"])
        await hosted.browseAppeared()
        let one = try image("one")
        let key = HostedImageKey(url: url("one.png"))
        var picked: [String] = []
        let before = fetcher.requests.count
        fetcher.hold(one.full)
        let first = try #require(hosted.pickOrCancel(one) { picked.append($0) })
        #expect(await fetcher.waitForRequests(before + 1))
        #expect(hosted.pickOrCancel(one) { picked.append($0) } == nil)
        fetcher.release(one.full)
        await first.value
        #expect(picked.isEmpty)
        #expect(hosted.fetches[key] == nil)
        #expect(!hosted.available.contains(key))
    }

    @Test func clickingAQueuedPickAgainCancelsItAndLeavesTheQueue() async throws {
        try serveCatalog(["one", "two", "three"])
        await hosted.browseAppeared()
        let images = try ["one", "two", "three"].map(image)
        let third = HostedImageKey(url: url("three.png"))
        var picked: [String] = []
        let before = fetcher.requests.count
        for image in images { fetcher.hold(image.full) }
        let running = images.prefix(2).map { hosted.select($0) }
        #expect(await fetcher.waitForRequests(before + 2))
        var queued: Task<Void, Never>?
        let didQueue = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            let timeout = DispatchWorkItem { once.resume(false) }
            once.setOnResumed { timeout.cancel() }
            hosted.onFetchQueued = { if $0 == third { once.resume(true) } }
            queued = hosted.pickOrCancel(images[2]) { picked.append($0) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + TestBounds.hangGuard, execute: timeout)
        }
        #expect(didQueue)
        let queuedTask = try #require(queued)
        #expect(hosted.pickOrCancel(images[2]) { picked.append($0) } == nil)
        await queuedTask.value
        #expect(hosted.fetches[third] == nil)
        #expect(fetcher.count(images[2].full) == 0)
        for image in images { fetcher.release(image.full) }
        for task in running { #expect(await task.value != nil) }
        #expect(picked.isEmpty)
    }

    @Test func pickCancelPickFetchesAFreshCopyAndAppliesIt() async throws {
        try serveCatalog(["one"])
        await hosted.browseAppeared()
        let one = try image("one")
        var picked: [Int] = []
        let before = fetcher.requests.count
        fetcher.hold(one.full)
        let first = try #require(hosted.pickOrCancel(one) { _ in picked.append(1) })
        #expect(await fetcher.waitForRequests(before + 1))
        #expect(hosted.pickOrCancel(one) { _ in picked.append(2) } == nil)
        let third = try #require(hosted.pickOrCancel(one) { _ in picked.append(3) })
        fetcher.release(one.full)
        await first.value
        await third.value
        #expect(picked == [3])
        #expect(fetcher.count(one.full) == 2)
    }

    @Test func clickingAJoinedDownloadAgainDropsThePickButKeepsTheFetch() async throws {
        try serveCatalog(["one"])
        await hosted.browseAppeared()
        let one = try image("one")
        var picked: [String] = []
        let before = fetcher.requests.count
        fetcher.hold(one.full)
        let elsewhere = hosted.select(one)
        #expect(await fetcher.waitForRequests(before + 1))
        let joined = try #require(hosted.pickOrCancel(one) { picked.append($0) })
        #expect(hosted.pickOrCancel(one) { picked.append($0) } == nil)
        fetcher.release(one.full)
        await joined.value
        #expect(await elsewhere.value != nil)
        #expect(picked.isEmpty)
        #expect(hosted.available.contains(HostedImageKey(url: url("one.png"))))
        #expect(fetcher.count(one.full) == 1)
    }

    @Test func clickingADifferentImageWhileOneDownloadsCancelsItAndAppliesTheNewOne() async throws {
        try serveCatalog(["one", "two"])
        await hosted.browseAppeared()
        let one = try image("one"), two = try image("two")
        var picked: [String] = []
        let before = fetcher.requests.count
        fetcher.hold(one.full)
        let first = try #require(hosted.pickOrCancel(one) { picked.append($0) })
        #expect(await fetcher.waitForRequests(before + 1))
        await hosted.pickOrCancel(two) { picked.append($0) }?.value
        fetcher.release(one.full)
        await first.value
        #expect(picked == [try #require(await hosted.select(two).value)])
        #expect(!hosted.available.contains(HostedImageKey(url: url("one.png"))))
    }

    @Test func clickingACachedImageTwicePicksItBothTimes() async throws {
        try serveCatalog(["one"])
        await hosted.browseAppeared()
        let one = try image("one")
        let path = try #require(await hosted.select(one).value)
        var picked: [String] = []
        await hosted.pickOrCancel(one) { picked.append($0) }?.value
        await hosted.pickOrCancel(one) { picked.append($0) }?.value
        #expect(picked == [path, path])
    }

    @Test func imageDroppedFromTheCatalogKeepsItsHostedCopy() async throws {
        try serveCatalog(["one", "two"])
        await hosted.browseAppeared()
        let path = try #require(await hosted.select(try image("one")).value)
        try serveCatalog(["two"], etag: "\"c2\"")
        await hosted.refresh(catalogURL)
        await hosted.reconcileAvailability()
        #expect(hosted.catalogs.first?.catalog?.allImages.map(\.title) == ["Picture two"])
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(hosted.available.isEmpty)
    }

    @Test func hostedImageStaysOutOfMyImages() async throws {
        try serveCatalog()
        await hosted.browseAppeared()
        _ = try #require(await hosted.select(try image("one")).value)
        await store.backgroundImages.refresh()
        #expect(store.backgroundImages.entries.isEmpty)
    }
}

@MainActor
struct HostedBackgroundPickTests {
    private let f: ProjectBackgroundFixture
    private let store: AppStateStore

    init() throws {
        f = try ProjectBackgroundFixture()
        store = f.appStore()
    }

    private func hostedPath() async throws -> String {
        try await f.copy(in: f.hostedFolder, width: 64, named: "Hosted.png")
    }

    @Test func appWideAdoptAcceptsAHostedPath() async throws {
        let path = try await hostedPath()
        let importer = TerminalBackgroundImageImporter(directory: f.appWideFolder, cleanup: .allButRetained)
        let adopted = try #require(await importer.adoptImage(path: path, from: store.backgroundImages.pickSources))
        #expect(adopted.hasPrefix(f.appWideFolder.path))
    }

    @Test func paneOverrideAdoptsAHostedPath() async throws {
        let path = try await hostedPath()
        let importer = TerminalBackgroundImageImporter(directory: f.paneFolder, cleanup: .keepAll)
        let adopted = try #require(await importer.adoptImage(path: path, from: store.backgroundImages.pickSources))
        #expect(adopted.hasPrefix(f.paneFolder.path))
    }

    @Test func hostedPathOutsidePickSourcesIsRefused() async throws {
        let path = try await hostedPath()
        let importer = TerminalBackgroundImageImporter(directory: f.paneFolder, cleanup: .keepAll)
        #expect(await importer.adoptImage(path: path, from: [store.backgroundImages.library.directory]) == nil)
    }
}
