// HostedBackgroundsModel.swift

import Foundation
import Observation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "HostedBackgroundsModel")

/// A hosted image's identity: its resolved full-size URL.
nonisolated struct HostedImageKey: Hashable, Sendable {
    let url: URL

    init(_ image: HostedBackgroundImage) { url = image.full }
    init(url: URL) { self.url = url }
}

nonisolated enum HostedFetchState: Equatable, Sendable {
    case fetching
    case failed(String)
}

nonisolated enum HostedCatalogProblem: Equatable, Sendable {
    case offlineShowingCache(String)
    case offlineNoCache(String)
    case invalid(String)
    case fetchFailed(String)
}

nonisolated struct HostedCatalogState: Equatable, Sendable, Identifiable {
    let url: URL
    let isBuiltIn: Bool
    var catalog: BackgroundCatalog?
    var isChecking = false
    var problem: HostedCatalogProblem?
    var lastChecked: Date?
    var failingSince: Date?

    var id: URL { url }
    var host: String { url.host ?? url.absoluteString }

    static let unreachableAfter: TimeInterval = 7 * 24 * 60 * 60

    /// Only a fetch failure counts, never an invalid body, and by elapsed time
    /// so repeated Check Now clicks can't trip it.
    func unreachableSince(now: Date) -> Date? {
        guard let failingSince, now.timeIntervalSince(failingSince) >= Self.unreachableAfter else { return nil }
        switch problem {
        case .offlineShowingCache, .offlineNoCache, .fetchFailed: return failingSince
        case .invalid, nil: return nil
        }
    }
}

/// What a hosted-background model needs from outside, so tests pass their own.
struct HostedBackgroundsDependencies {
    var fetcher: BackgroundCatalogFetching
    var cacheRoot: URL
    var temporaryRoot: URL
    var clock: SchedulingClock
}

/// The Background Sets tab. Nothing is fetched before `browseAppeared`, and a
/// full-size image only from `select`. Every write follows a user action or an
/// `await`, and writes only on change.
@MainActor
@Observable
final class HostedBackgroundsModel {
    static let refreshInterval: TimeInterval = 10 * 60
    static let maxConcurrentFetches = 2

    private(set) var catalogs: [HostedCatalogState] = []
    private(set) var fetches: [HostedImageKey: HostedFetchState] = [:]
    private(set) var available: Set<HostedImageKey> = []
    /// In the order added. Written only by `addCatalog` and `removeCatalog`.
    private(set) var userCatalogURLs: [URL]
    private(set) var isAddingCatalog = false

    @ObservationIgnored let store: HostedImageStore
    @ObservationIgnored let cache: BackgroundCatalogCache
    @ObservationIgnored let thumbnails: HostedThumbnailLoader
    @ObservationIgnored private let fetcher: BackgroundCatalogFetching
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let clock: SchedulingClock
    @ObservationIgnored private var running: [HostedImageKey: (id: UUID, task: Task<String?, Never>)] = [:]
    @ObservationIgnored private var lastRefresh: [URL: Date] = [:]
    @ObservationIgnored private var refreshing: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored private var activeFetches = 0
    @ObservationIgnored private var fetchWaiters: [(key: HostedImageKey, continuation: CheckedContinuation<Bool, Never>)] = []
    @ObservationIgnored private var pickGeneration = 0
    /// `ownsFetch` is false when the pick joined a fetch something else started,
    /// so superseding the pick leaves that fetch running.
    @ObservationIgnored private var pendingPick: (key: HostedImageKey, ownsFetch: Bool)?
    /// Test seam: a fetch is waiting for a free slot.
    @ObservationIgnored var onFetchQueued: ((HostedImageKey) -> Void)?
    /// Test seam: `removeCatalog` has dropped the URL and is about to wait
    /// for a refresh still running.
    @ObservationIgnored var onCatalogForgotten: ((URL) -> Void)?

    init(imageDirectory: URL, dependencies: HostedBackgroundsDependencies, defaults: UserDefaults) {
        self.fetcher = dependencies.fetcher
        self.cache = BackgroundCatalogCache(root: dependencies.cacheRoot)
        self.store = HostedImageStore(directory: imageDirectory, fetcher: dependencies.fetcher, temporaryRoot: dependencies.temporaryRoot)
        self.thumbnails = HostedThumbnailLoader(fetcher: dependencies.fetcher, cache: cache)
        self.defaults = defaults
        self.clock = dependencies.clock
        self.userCatalogURLs = SettingsPreference.resolvedBackgroundCatalogURLs(defaults: defaults)
    }

    var catalogURLs: [URL] { [BackgroundCatalog.builtInURL] + userCatalogURLs }

    /// The built-in catalog waits for the first Browse; a user URL was asked for.
    var scheduledCatalogURLs: [URL] {
        hasBrowsed ? catalogURLs : userCatalogURLs
    }

    /// One per catalog, built-in first, including ones not loaded yet.
    var catalogRows: [HostedCatalogState] {
        catalogURLs.map { url in
            state(url) ?? HostedCatalogState(url: url, isBuiltIn: url == BackgroundCatalog.builtInURL)
        }
    }

    nonisolated var imageDirectory: URL { store.directory }

    var hasBrowsed: Bool { SettingsPreference.resolvedBackgroundCatalogsBrowsed(defaults: defaults) }

    /// Runs only from the Background Sets view's `.task`.
    func browseAppeared() async {
        SettingsPreference.markBackgroundCatalogsBrowsed(defaults: defaults)
        await loadCachedStates()
        let urls = catalogURLs
        let now = clock.now
        for url in urls {
            if let last = lastRefresh[url], now.timeIntervalSince(last) < Self.refreshInterval { continue }
            await refresh(url)
        }
        await reconcileAvailability()
    }

    /// Settings' `.task`: cached copies and check state only, no network.
    func loadCatalogRows() async {
        await loadCachedStates()
    }

    private func loadCachedStates() async {
        for url in catalogURLs where state(url) == nil {
            let cached = await cache.cachedCatalog(for: url)
            let checks = await cache.state(for: url)
            if state(url) == nil {
                update(url) {
                    $0.catalog = cached?.catalog
                    $0.lastChecked = checks.lastChecked
                    $0.failingSince = checks.failingSince
                }
            }
        }
    }

    /// Validates, fetches once and parses before anything is saved. Doesn't
    /// mark Browse as opened.
    func addCatalog(_ text: String) async -> Result<URL, BackgroundCatalogURLRefusal> {
        let url: URL
        switch BackgroundCatalogURLs.normalize(text) {
        case .success(let normalized): url = normalized
        case .failure(let refusal): return .failure(refusal)
        }
        if let refusal = addRefusal(for: url) { return .failure(refusal) }
        guard !isAddingCatalog else { return .failure(.fetch("Another catalog is being added")) }
        isAddingCatalog = true
        defer { isAddingCatalog = false }

        let host = url.host ?? url.absoluteString
        let response: HostedFetchResponse
        do {
            response = try await fetcher.fetch(HostedFetchRequest(
                url: url,
                byteLimit: Int64(BackgroundCatalogLimits.catalogBytes),
                timeout: BackgroundCatalogLimits.catalogTimeout
            ), progress: nil)
        } catch {
            return .failure(.fetch(error.message(host: host)))
        }
        let body = response.body ?? Data()
        let catalog: BackgroundCatalog
        do {
            catalog = try BackgroundCatalogParser.parse(body, catalogURL: url)
        } catch {
            return .failure(.fetch(error.message))
        }
        if let refusal = addRefusal(for: url) { return .failure(refusal) }

        let now = clock.now
        await cache.store(body: body, validators: HostedValidators(etag: response.etag, lastModified: response.lastModified), for: url, at: now)
        userCatalogURLs.append(url)
        SettingsPreference.setBackgroundCatalogURLs(userCatalogURLs, defaults: defaults)
        update(url) {
            $0.catalog = catalog
            $0.lastChecked = now
            $0.failingSince = nil
            $0.problem = nil
        }
        lastRefresh[url] = now
        logger.info("added a background catalog")
        return .success(url)
    }

    private func addRefusal(for url: URL) -> BackgroundCatalogURLRefusal? {
        if catalogURLs.contains(url) { return .duplicate }
        if userCatalogURLs.count >= BackgroundCatalogURLs.maxUserCatalogs { return .tooMany }
        return nil
    }

    /// Hosted copy files and every use's own copy stay; only this catalog's
    /// records, cache and row go.
    func removeCatalog(_ url: URL) async {
        guard url != BackgroundCatalog.builtInURL, userCatalogURLs.contains(url) else { return }
        // First, so no refresh or `update` still running can bring it back.
        userCatalogURLs.removeAll { $0 == url }
        SettingsPreference.setBackgroundCatalogURLs(userCatalogURLs, defaults: defaults)
        onCatalogForgotten?(url)
        if let running = refreshing[url] { await running.value }

        var removedImages = Set(await catalog(for: url)?.allImages.map(\.full) ?? [])
        for other in catalogURLs {
            for image in await catalog(for: other)?.allImages ?? [] { removedImages.remove(image.full) }
        }
        await store.removeRecords(for: removedImages)
        await cache.removeAll(for: url)
        lastRefresh[url] = nil
        if catalogs.contains(where: { $0.url == url }) { catalogs.removeAll { $0.url == url } }
        await reconcileAvailability()
    }

    private func catalog(for url: URL) async -> BackgroundCatalog? {
        if let held = state(url)?.catalog { return held }
        return await cache.cachedCatalog(for: url)?.catalog
    }

    /// The banner's Retry, and the hook a scheduled refresh calls. One per catalog at a time.
    func refresh(_ url: URL) async {
        if let running = refreshing[url] {
            await running.value
            return
        }
        let task = Task { await performRefresh(url) }
        refreshing[url] = task
        await task.value
        refreshing[url] = nil
    }

    private func performRefresh(_ url: URL) async {
        lastRefresh[url] = clock.now
        if state(url) == nil {
            let cached = await cache.cachedCatalog(for: url)
            update(url) { $0.catalog = cached?.catalog }
        }
        update(url) { $0.isChecking = true }
        let validators = await cache.state(for: url)
        let hasCopy = state(url)?.catalog != nil
        let request = HostedFetchRequest(
            url: url,
            etag: hasCopy ? validators.etag : nil,
            lastModified: hasCopy ? validators.lastModified : nil,
            byteLimit: Int64(BackgroundCatalogLimits.catalogBytes),
            timeout: BackgroundCatalogLimits.catalogTimeout
        )
        let host = url.host ?? url.absoluteString
        let response: HostedFetchResponse
        do {
            response = try await fetcher.fetch(request, progress: nil)
        } catch {
            guard catalogURLs.contains(url) else { return }
            let message = error.message(host: host)
            await cache.markChecked(for: url, at: clock.now, error: message)
            await loadChecks(url)
            let problem: HostedCatalogProblem
            switch error {
            case .unreachable, .timedOut:
                problem = hasCopy ? .offlineShowingCache(host) : .offlineNoCache(host)
            default:
                problem = .fetchFailed(message)
            }
            update(url) { $0.isChecking = false; $0.problem = problem }
            return
        }
        // A catalog removed while this fetch ran must leave no cache behind.
        guard catalogURLs.contains(url) else { return }
        if response.status == 304 {
            await cache.markChecked(for: url, at: clock.now, error: nil)
            await loadChecks(url)
            update(url) { $0.isChecking = false; $0.problem = nil }
            return
        }
        let body = response.body ?? Data()
        do {
            let catalog = try BackgroundCatalogParser.parse(body, catalogURL: url)
            await cache.store(body: body, validators: HostedValidators(etag: response.etag, lastModified: response.lastModified), for: url, at: clock.now)
            await loadChecks(url)
            update(url) { $0.catalog = catalog; $0.isChecking = false; $0.problem = nil }
        } catch {
            await cache.markChecked(for: url, at: clock.now, error: error.message)
            await loadChecks(url)
            update(url) { $0.isChecking = false; $0.problem = .invalid(error.message) }
        }
    }

    private func loadChecks(_ url: URL) async {
        let checks = await cache.state(for: url)
        update(url) {
            $0.lastChecked = checks.lastChecked
            $0.failingSince = checks.failingSince
        }
    }

    /// Returns the local path once the full-size copy is held, or nil after a
    /// failure or cancellation. Selecting a key already fetching returns its
    /// task, unless that task was cancelled: then a new fetch starts once the
    /// cancelled one has unwound, so the two never overlap.
    @discardableResult
    func select(_ image: HostedBackgroundImage) -> Task<String?, Never> {
        let key = HostedImageKey(image)
        let previous = running[key]?.task
        if let previous, !previous.isCancelled { return previous }
        let id = UUID()
        let task = Task<String?, Never> { [weak self] in
            _ = await previous?.value
            guard let self else { return nil }
            return await self.runSelect(image, key: key, id: id)
        }
        running[key] = (id, task)
        return task
    }

    private func isFetching(_ key: HostedImageKey) -> Bool {
        guard let task = running[key]?.task else { return false }
        return !task.isCancelled
    }

    private func runSelect(_ image: HostedBackgroundImage, key: HostedImageKey, id: UUID) async -> String? {
        defer { if running[key]?.id == id { running[key] = nil } }
        guard !Task.isCancelled else {
            setFetch(key, nil)
            return nil
        }
        if let path = await store.localPath(for: image) {
            setFetch(key, nil)
            insertAvailable(key)
            return path
        }
        setFetch(key, .fetching)
        guard await acquireFetchSlot(for: key) else {
            setFetch(key, nil)
            return nil
        }
        defer { releaseFetchSlot() }
        guard !Task.isCancelled else {
            setFetch(key, nil)
            return nil
        }
        do {
            let path = try await store.fetch(image)
            setFetch(key, nil)
            insertAvailable(key)
            return path
        } catch {
            if error == .fetch(.cancelled) || Task.isCancelled {
                setFetch(key, nil)
            } else {
                logger.error("hosted image fetch failed: \(String(describing: error), privacy: .public)")
                setFetch(key, .failed(error.message(host: key.url.host ?? "")))
            }
            return nil
        }
    }

    func cancelFetch(_ key: HostedImageKey) {
        running[key]?.task.cancel()
        if let index = fetchWaiters.firstIndex(where: { $0.key == key }) {
            fetchWaiters.remove(at: index).continuation.resume(returning: false)
        }
    }

    func cancelAllFetches() {
        for entry in running.values { entry.task.cancel() }
        let waiters = fetchWaiters
        fetchWaiters.removeAll()
        for waiter in waiters { waiter.continuation.resume(returning: false) }
    }

    /// A Choose… sheet's pick: `onPicked` runs only if this is still the
    /// sheet's latest pick when the fetch finishes. A later pick of a different
    /// image, or `supersedePicks`, drops it and cancels its fetch, unless the
    /// pick joined a fetch something else started.
    @discardableResult
    func pick(_ image: HostedBackgroundImage, onPicked: @escaping @MainActor (String) -> Void) -> Task<Void, Never> {
        let key = HostedImageKey(image)
        let ownsFetch: Bool
        if let pendingPick, pendingPick.key == key {
            ownsFetch = pendingPick.ownsFetch || !isFetching(key)
        } else {
            releasePendingPick()
            ownsFetch = !isFetching(key)
        }
        pickGeneration += 1
        let generation = pickGeneration
        pendingPick = (key, ownsFetch)
        let fetch = select(image)
        return Task { [weak self] in
            let path = await fetch.value
            guard let self, generation == self.pickGeneration else { return }
            self.pendingPick = nil
            guard let path else { return }
            onPicked(path)
        }
    }

    /// The sheet picked something else, was cancelled or went away: no
    /// earlier hosted pick may deliver, and a fetch it started stops.
    func supersedePicks() {
        pickGeneration += 1
        releasePendingPick()
    }

    private func releasePendingPick() {
        if let pendingPick, pendingPick.ownsFetch { cancelFetch(pendingPick.key) }
        pendingPick = nil
    }

    func reconcileAvailability() async {
        var found = Set<HostedImageKey>()
        for state in catalogs {
            for image in state.catalog?.allImages ?? [] where await store.localPath(for: image) != nil {
                found.insert(HostedImageKey(image))
            }
        }
        if found != available { available = found }
    }

    func thumbnail(for image: HostedBackgroundImage, catalogURL: URL) async -> BackgroundImageThumbnail {
        await thumbnails.thumbnail(for: image, catalogURL: catalogURL)
    }

    /// False when `cancelFetch` takes the key out of the queue before a slot frees.
    private func acquireFetchSlot(for key: HostedImageKey) async -> Bool {
        if activeFetches < Self.maxConcurrentFetches {
            activeFetches += 1
            return true
        }
        if Task.isCancelled { return false }
        return await withCheckedContinuation {
            fetchWaiters.append((key, $0))
            onFetchQueued?(key)
        }
    }

    /// Hands the slot straight to the next waiter, so `activeFetches` stays counted.
    private func releaseFetchSlot() {
        if fetchWaiters.isEmpty {
            activeFetches -= 1
        } else {
            fetchWaiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func state(_ url: URL) -> HostedCatalogState? {
        catalogs.first { $0.url == url }
    }

    private func update(_ url: URL, _ change: (inout HostedCatalogState) -> Void) {
        let order = catalogURLs
        guard order.contains(url) else { return }
        var list = catalogs
        if let index = list.firstIndex(where: { $0.url == url }) {
            change(&list[index])
        } else {
            var fresh = HostedCatalogState(url: url, isBuiltIn: url == BackgroundCatalog.builtInURL)
            change(&fresh)
            list.append(fresh)
        }
        list.sort { (order.firstIndex(of: $0.url) ?? .max) < (order.firstIndex(of: $1.url) ?? .max) }
        if list != catalogs { catalogs = list }
    }

    private func setFetch(_ key: HostedImageKey, _ value: HostedFetchState?) {
        if fetches[key] != value { fetches[key] = value }
    }

    private func insertAvailable(_ key: HostedImageKey) {
        if !available.contains(key) { available.insert(key) }
    }
}
