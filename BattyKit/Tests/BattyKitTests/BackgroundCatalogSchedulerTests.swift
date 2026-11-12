// BackgroundCatalogSchedulerTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Time passes only through `TestClock.advance`. A tick has finished when the
/// scheduler sleeps again, which `waitForSleepers(1)` awaits as an event.
@MainActor
struct BackgroundCatalogSchedulerTests {
    private let f: ProjectBackgroundFixture
    private let store: AppStateStore
    private var hosted: HostedBackgroundsModel { store.backgroundImages.hosted }
    private var fetcher: FakeBackgroundCatalogFetcher { f.catalogFetcher }
    private var defaults: UserDefaults { f.testDefaults.defaults }
    private var server: HostedCatalogServer { HostedCatalogServer(fetcher: fetcher) }
    private let builtIn = BackgroundCatalog.builtInURL
    private let userURL = URL(string: "https://catalogs.example.com/catalog.json")!
    private let otherURL = URL(string: "https://other.example.com/catalog.json")!
    private let scheduler: BackgroundCatalogScheduler

    private static let day: Duration = .seconds(24 * 60 * 60)

    init() throws {
        f = try ProjectBackgroundFixture()
        store = f.appStore()
        scheduler = BackgroundCatalogScheduler(hosted: store.backgroundImages.hosted, clock: f.clock, defaults: f.testDefaults.defaults)
    }

    /// Starts the scheduler and runs the launch check.
    private func startAndRunLaunchCheck() async {
        scheduler.start()
        #expect(await f.clock.waitForSleepers(1))
        #expect(await f.clock.advance(by: BackgroundCatalogScheduler.launchDelay) == 1)
        #expect(await f.clock.waitForSleepers(1))
    }

    private func tick(_ duration: Duration = day) async {
        #expect(await f.clock.advance(by: duration) == 1)
        #expect(await f.clock.waitForSleepers(1))
    }

    private func addUserCatalog(_ url: URL, etag: String? = "\"c1\"", lastModified: String? = nil) async throws {
        try server.serve(url, etag: etag, lastModified: lastModified)
        _ = try #require(try? await hosted.addCatalog(url.absoluteString).get())
    }

    @Test func nothingIsFetchedBeforeTheLaunchDelay() async throws {
        try await addUserCatalog(userURL)
        let before = fetcher.requests.count
        scheduler.start()
        #expect(await f.clock.waitForSleepers(1))
        #expect(await f.clock.advance(by: .seconds(29)) == 0)
        #expect(fetcher.requests.count == before)
        #expect(await f.clock.advance(by: .seconds(1)) == 1)
        #expect(await f.clock.waitForSleepers(1))
        #expect(fetcher.requests.count == before + 1)
        scheduler.stop()
    }

    @Test func launchCheckSkipsTheBuiltInCatalogUntilBrowsed() async throws {
        try server.serve(builtIn)
        await startAndRunLaunchCheck()
        #expect(fetcher.count(builtIn) == 0)
        SettingsPreference.markBackgroundCatalogsBrowsed(defaults: defaults)
        await tick()
        #expect(fetcher.count(builtIn) == 1)
        scheduler.stop()
    }

    @Test func launchCheckFetchesUserCatalogsBeforeAnyBrowse() async throws {
        try await addUserCatalog(userURL)
        await startAndRunLaunchCheck()
        #expect(fetcher.count(userURL) == 2)
        #expect(!hosted.hasBrowsed)
        scheduler.stop()
    }

    @Test func everyTwentyFourHoursEachCatalogIsFetchedOnceWithItsValidators() async throws {
        try await addUserCatalog(userURL, etag: "\"u1\"", lastModified: "Mon")
        try await addUserCatalog(otherURL, etag: "\"o1\"")
        await startAndRunLaunchCheck()
        #expect(fetcher.count(userURL) == 2)
        #expect(fetcher.count(otherURL) == 2)
        await tick()
        #expect(fetcher.count(userURL) == 3)
        #expect(fetcher.count(otherURL) == 3)
        let last = fetcher.requests.filter { $0.url == userURL }.last
        #expect(last?.etag == "\"u1\"")
        #expect(last?.lastModified == "Mon")
        #expect(fetcher.requests.filter { $0.url == otherURL }.last?.etag == "\"o1\"")
        scheduler.stop()
    }

    @Test func notModifiedKeepsTheCachedCopyAndUpdatesLastChecked() async throws {
        try await addUserCatalog(userURL)
        let added = f.clock.now
        fetcher.set(.notModified, for: userURL)
        await startAndRunLaunchCheck()
        let row = try #require(hosted.catalogRows.last)
        #expect(row.catalog?.allImages.count == 2)
        #expect(row.problem == nil)
        #expect(row.lastChecked == added.addingTimeInterval(30))
        #expect(await hosted.cache.cachedCatalog(for: userURL)?.state.etag == "\"c1\"")
        scheduler.stop()
    }

    @Test func catalogsAreFetchedOneAtATime() async throws {
        try await addUserCatalog(userURL)
        try await addUserCatalog(otherURL)
        let before = fetcher.requests.count
        fetcher.hold(userURL)
        scheduler.start()
        #expect(await f.clock.waitForSleepers(1))
        #expect(await f.clock.advance(by: BackgroundCatalogScheduler.launchDelay) == 1)
        #expect(await fetcher.waitForRequests(before + 1))
        #expect(fetcher.requests.count == before + 1)
        #expect(fetcher.requests.last?.url == userURL)
        fetcher.release(userURL)
        #expect(await f.clock.waitForSleepers(1))
        #expect(fetcher.requests.count == before + 2)
        #expect(fetcher.requests.last?.url == otherURL)
        scheduler.stop()
    }

    @Test func turningAutomaticChecksOffStopsScheduledFetches() async throws {
        try await addUserCatalog(userURL)
        defaults.set(false, forKey: SettingsPreference.backgroundCatalogsAutoCheckKey)
        await startAndRunLaunchCheck()
        await tick()
        #expect(fetcher.count(userURL) == 1)
        defaults.set(true, forKey: SettingsPreference.backgroundCatalogsAutoCheckKey)
        await tick()
        #expect(fetcher.count(userURL) == 2)
        scheduler.stop()
    }

    @Test func aFailedScheduledCheckKeepsTheLastCopyAndShowsTheError() async throws {
        try await addUserCatalog(userURL)
        fetcher.set(.failure(.server(503)), for: userURL)
        await startAndRunLaunchCheck()
        let row = try #require(hosted.catalogRows.last)
        #expect(row.catalog?.allImages.count == 2)
        #expect(row.problem == .fetchFailed("Server error (503)"))
        #expect(await hosted.cache.cachedCatalog(for: userURL)?.catalog.allImages.count == 2)
        #expect(await hosted.cache.state(for: userURL).lastError == "Server error (503)")
        scheduler.stop()
    }

    @Test func sevenDaysOfFailuresShowUnreachableSince() async throws {
        try await addUserCatalog(userURL)
        fetcher.set(.failure(.unreachable), for: userURL)
        await startAndRunLaunchCheck()
        let firstFailure = f.clock.now
        for _ in 1...6 {
            #expect(hosted.catalogRows.last?.unreachableSince(now: f.clock.now) == nil)
            await tick()
        }
        #expect(hosted.catalogRows.last?.unreachableSince(now: f.clock.now) == nil)
        await tick()
        #expect(hosted.catalogRows.last?.unreachableSince(now: f.clock.now) == firstFailure)
        try server.serve(userURL)
        await tick()
        #expect(hosted.catalogRows.last?.unreachableSince(now: f.clock.now) == nil)
        #expect(hosted.catalogRows.last?.failingSince == nil)
        scheduler.stop()
    }

    @Test func anInvalidBodyNeverShowsUnreachableSince() async throws {
        try await addUserCatalog(userURL)
        fetcher.set(.ok(Data("<html>".utf8)), for: userURL)
        await startAndRunLaunchCheck()
        for _ in 1...8 { await tick() }
        let row = try #require(hosted.catalogRows.last)
        #expect(row.failingSince != nil)
        #expect(row.problem == .invalid("Not a background catalog: (root)"))
        #expect(row.unreachableSince(now: f.clock.now) == nil)
        scheduler.stop()
    }

    @Test func stopCancelsTheSchedule() async throws {
        scheduler.start()
        #expect(await f.clock.waitForSleepers(1))
        scheduler.stop()
        #expect(f.clock.pendingCount == 0)
    }

    @Test func startIsIdempotent() async throws {
        scheduler.start()
        scheduler.start()
        #expect(await f.clock.waitForSleepers(1))
        #expect(f.clock.pendingCount == 1)
        scheduler.stop()
    }
}
