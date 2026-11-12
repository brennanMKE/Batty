// TabImageResolutionTests.swift

import Foundation
import Testing
@testable import BattyKit

private let noContent: @MainActor (PaneContentKind) -> (any PaneContentLifecycle)? = { _ in nil }

@MainActor
struct TabImageResolutionTests {
    private let f: ProjectBackgroundFixture
    private let clock = ManualNow()

    init() throws { f = try ProjectBackgroundFixture() }

    private func url(_ name: String) -> URL { URL(string: "https://batty.sstools.co/backgrounds/\(name).png")! }

    private func serve(_ name: String, width: Int = 64) throws -> URL {
        let url = url(name)
        f.catalogFetcher.set(.ok(try BackgroundTestImage.encoded(width: width, height: 64)), for: url)
        return url
    }

    private func store(limits: DownloadedImageCache.Limits = .standard) -> AppStateStore {
        let store = f.appStore()
        let clock = clock
        store.downloadedImages = DownloadedImageCache(
            directory: f.downloadedFolder, fetcher: f.catalogFetcher,
            temporaryRoot: f.base.appendingPathComponent("downloads", isDirectory: true),
            limits: limits, now: { clock.date })
        return store
    }

    private func tabbed(_ images: [ProjectTabImage], name: String = "Tabs", paths: [String?]? = nil) -> Project {
        let tabs = images.enumerated().map { index, image in
            ProjectTab(title: "T\(index)", background: projectBackgroundValue(path: paths?[index] ?? nil), image: image)
        }
        return f.project(name: name, background: nil, layout: ProjectLayout(root: .pane(.terminal(tabs: tabs))))
    }

    private func open(_ store: AppStateStore, _ project: Project, upsert: Bool = true) throws -> SessionRuntime {
        if upsert { try store.projectStore.upsert(project) }
        return try store.openProject(id: project.id, mode: .openNew, contentFactory: noContent).session
    }

    private func tabs(_ session: SessionRuntime) -> [TabRuntime] { session.tree.allPanes.flatMap(\.tabs) }

    private func storedPaths(_ store: AppStateStore, _ id: UUID) -> [String?] {
        store.projectStore.project(id: id)?.layout.panes.flatMap(\.tabs).map { $0.background?.imagePath } ?? []
    }

    private func settle(_ store: AppStateStore) async {
        await store.tabImageRequest?.value
    }

    @Test func openUsesALocalCopyFoundByDigest() async throws {
        let store = store()
        let path = try await f.copy()
        let digest = try #require(TerminalBackgroundImageImporter.digest(ofPath: path))
        let session = try open(store, tabbed([.custom(digest: digest, name: "Photo")]))
        #expect(tabs(session)[0].backgroundOverride?.imagePath == path)
        #expect(f.catalogFetcher.requests.isEmpty)
    }

    @Test func openUsesALocalCopyFoundByURL() async throws {
        let store = store()
        let url = try serve("canal")
        let hosted = HostedImageStore(directory: f.hostedFolder, fetcher: f.catalogFetcher, temporaryRoot: f.base.appendingPathComponent("h-tmp"))
        _ = try await hosted.fetch(HostedBackgroundImage(title: "Canal", full: url, thumbnail: url))
        let session = try open(store, tabbed([.hosted(url: url, name: "Canal")]))
        let path = try #require(tabs(session)[0].backgroundOverride?.imagePath)
        #expect(path.hasPrefix(f.projectFolder.path))
        await settle(store)
        #expect(f.catalogFetcher.count(url) == 1)
    }

    @Test func openUsingACachedCopyTouchesIt() async throws {
        let store = store()
        let bytes = try BackgroundTestImage.encoded(width: 72, height: 64)
        let digest = BackgroundTestImage.digest(of: bytes)
        _ = await store.downloadedImages.insertVerified(bytes: bytes, digest: digest, name: "Cached", pinned: [])
        let before = try #require(await store.downloadedImages.allEntries().first?.lastUsedAt)
        clock.advance()
        let session = try open(store, tabbed([.custom(digest: digest, name: "Cached")]))
        #expect(tabs(session)[0].backgroundOverride?.imagePath?.hasPrefix(f.downloadedFolder.path) == true)
        await settle(store)
        #expect(try #require(await store.downloadedImages.allEntries().first?.lastUsedAt) > before)
    }

    @Test func openWithAMissingImageOpensWithoutItAndDownloads() async throws {
        let store = store()
        let url = try serve("canal")
        let project = tabbed([.hosted(url: url, name: "Canal")])
        let session = try open(store, project)
        let tab = tabs(session)[0]
        #expect(tab.backgroundOverride == projectBackgroundValue(path: nil))
        #expect(!backgroundLines(tab).contains { $0.hasPrefix("background-image = ") })
        await settle(store)
        let path = try #require(tab.backgroundOverride?.imagePath)
        #expect(path.hasPrefix(f.downloadedFolder.path))
        #expect(storedPaths(store, project.id) == [path])
        #expect(tab.projectBackgroundSeed == tab.backgroundOverride)
    }

    @Test func arrivalAppliesToAnUnchangedTabOnly() async throws {
        let store = store()
        let url = try serve("canal")
        let image = ProjectTabImage.hosted(url: url, name: "Canal")
        let session = try open(store, tabbed([image, image]))
        let changed = secondBackgroundValue(path: nil)
        tabs(session)[1].setBackgroundOverride(changed)
        await settle(store)
        #expect(tabs(session)[0].backgroundOverride?.imagePath != nil)
        #expect(tabs(session)[1].backgroundOverride == changed)
    }

    @Test func arrivalRecordsThePathWithoutStampingOrPublishing() async throws {
        let store = store()
        let url = try serve("canal")
        let project = tabbed([.hosted(url: url, name: "Canal")])
        try store.projectStore.upsert(project)
        let stamped = store.projectStore.project(id: project.id)?.modifiedAt
        _ = try open(store, project, upsert: false)
        await settle(store)
        #expect(storedPaths(store, project.id).first ?? nil != nil)
        #expect(store.projectStore.project(id: project.id)?.modifiedAt == stamped)
    }

    @Test func twoSessionsWaitingForOneImageMakeOneRequest() async throws {
        let store = store()
        let url = try serve("canal")
        let project = tabbed([.hosted(url: url, name: "Canal")])
        let first = try open(store, project)
        let second = try open(store, project, upsert: false)
        await settle(store)
        #expect(f.catalogFetcher.count(url) == 1)
        #expect(tabs(first)[0].backgroundOverride?.imagePath != nil)
        #expect(tabs(second)[0].backgroundOverride?.imagePath != nil)
    }

    @Test func failedHostedDownloadSetsTheSessionProblem() async throws {
        let store = store()
        let url = url("gone")
        f.catalogFetcher.set(.failure(.notFound), for: url)
        let session = try open(store, tabbed([.hosted(url: url, name: "Gone")]))
        #expect(session.projectBackgroundImageProblem == nil)
        await settle(store)
        #expect(session.projectBackgroundImageProblem == .missing)
    }

    @Test func evictedImageIsRedownloadedOnNextOpen() async throws {
        let store = store(limits: .init(count: 1, bytes: .max))
        let a = try serve("a", width: 64)
        let b = try serve("b", width: 72)
        let projectA = tabbed([.hosted(url: a, name: "A")], name: "A")
        let sessionA = try open(store, projectA)
        await settle(store)
        #expect(storedPaths(store, projectA.id).first ?? nil != nil)
        store.removeSession(id: sessionA.id)
        clock.advance()
        _ = try open(store, tabbed([.hosted(url: b, name: "B")], name: "B"))
        await settle(store)
        #expect(storedPaths(store, projectA.id) == [nil])
        let again = try open(store, projectA, upsert: false)
        await settle(store)
        #expect(f.catalogFetcher.count(a) == 2)
        #expect(tabs(again)[0].backgroundOverride?.imagePath != nil)
    }

    @Test func evictionClearsStoredPathsWithoutStamping() async throws {
        let store = store(limits: .init(count: 1, bytes: .max))
        let a = try serve("a", width: 64)
        let b = try serve("b", width: 72)
        let projectA = tabbed([.hosted(url: a, name: "A")], name: "A")
        let sessionA = try open(store, projectA)
        await settle(store)
        let stamped = store.projectStore.project(id: projectA.id)?.modifiedAt
        store.removeSession(id: sessionA.id)
        clock.advance()
        _ = try open(store, tabbed([.hosted(url: b, name: "B")], name: "B"))
        await settle(store)
        #expect(storedPaths(store, projectA.id) == [nil])
        #expect(store.projectStore.project(id: projectA.id)?.layout.panes[0].tabs[0].image == .hosted(url: a, name: "A"))
        #expect(store.projectStore.project(id: projectA.id)?.modifiedAt == stamped)
    }

    @Test func anOpenTabsImageIsPinnedAgainstEviction() async throws {
        let store = store(limits: .init(count: 1, bytes: .max))
        let a = try serve("a", width: 64)
        let b = try serve("b", width: 72)
        let projectA = tabbed([.hosted(url: a, name: "A")], name: "A")
        let sessionA = try open(store, projectA)
        await settle(store)
        let path = try #require(tabs(sessionA)[0].backgroundOverride?.imagePath)
        clock.advance()
        _ = try open(store, tabbed([.hosted(url: b, name: "B")], name: "B"))
        await settle(store)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(storedPaths(store, projectA.id) == [path])
    }

    @Test func noDownloadAtLaunchOrOnARemoteChange() async throws {
        let store = store()
        let url = try serve("canal")
        let local = f.project(name: "Shared", background: nil)
        let merged = ProjectSyncMerge.apply(
            remote: [local.id: .record({ var p = tabbed([.hosted(url: url, name: "Canal")], name: "Shared"); p.id = local.id; p.isShared = true; p.modifiedAt = Date(); return p.syncRecord(home: NSHomeDirectory()) }())],
            to: [], home: NSHomeDirectory(), now: Date())
        for var each in merged {
            each.isShared = false
            try store.projectStore.upsert(each)
        }
        _ = AppStateStore(preferences: f.testDefaults.defaults, projectsFileURL: f.projectsFile)
        #expect(store.tabImageRequest == nil)
        #expect(f.catalogFetcher.requests.isEmpty)
        #expect(store.projectStore.projects.first?.layout.panes[0].tabs[0].image != nil)
    }

    @Test func customTabImageWithoutATransportOpensWithoutItAndRequestsNothing() async throws {
        let store = store()
        let digest = String(repeating: "c", count: 64)
        let session = try open(store, tabbed([.custom(digest: digest, name: "Elsewhere")]))
        await settle(store)
        #expect(store.sharedProjectImages == nil)
        #expect(tabs(session)[0].backgroundOverride == projectBackgroundValue(path: nil))
        #expect(f.catalogFetcher.requests.isEmpty)
    }

    @Test func editorLoadingAProjectRequestsItsTabImages() async throws {
        let store = store()
        let url = try serve("canal")
        let project = tabbed([.hosted(url: url, name: "Canal")])
        try store.projectStore.upsert(project)
        let model = ProjectEditorViewModel(
            store: store.projectStore, initialSelection: project.id, directoryExists: { _ in true },
            backgrounds: f.library, projectLoaded: { [weak store] in store?.projectEditorShowed($0) })
        store.projectEditorModelOverride = { model }
        await settle(store)
        #expect(f.catalogFetcher.count(url) == 1)
        #expect(storedPaths(store, project.id).first ?? nil != nil)
    }

    @Test func saveKeepsACachedPathCacheOwned() async throws {
        let store = store()
        let url = try serve("canal")
        let project = tabbed([.hosted(url: url, name: "Canal")])
        let session = try open(store, project)
        await settle(store)
        let tab = tabs(session)[0]
        let cached = try #require(tab.backgroundOverride?.imagePath)
        tab.setBackgroundOverride(tab.backgroundOverride?.withTerminalOpacity(0.3))
        let draft = SaveSessionAsProject.draft(for: session, destination: .update(project.id), store: store)
        let saved = draft.layout.panes[0].tabs[0]
        #expect(saved.background?.imagePath == cached)
        #expect(saved.image == .hosted(url: url, name: "Canal"))
        let digest = try #require(TerminalBackgroundImageImporter.digest(ofPath: cached))
        #expect(!FileManager.default.fileExists(atPath: f.projectFolder.appendingPathComponent(digest).path))
    }

    @Test func removeInBackgroundImagesDropsTheCachedCopyAndKeepsTheIdentity() async throws {
        let store = store()
        let url = try serve("canal")
        let project = tabbed([.hosted(url: url, name: "Canal")])
        _ = try open(store, project)
        await settle(store)
        let cached = try #require(storedPaths(store, project.id).first ?? nil)
        let digest = try #require(TerminalBackgroundImageImporter.digest(ofPath: cached))
        try store.clearBackgroundImageUses(digest: digest)
        await settle(store)
        #expect(await store.downloadedImages.allEntries().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: cached))
        #expect(storedPaths(store, project.id) == [nil])
        #expect(store.projectStore.project(id: project.id)?.layout.panes[0].tabs[0].image == .hosted(url: url, name: "Canal"))
    }
}
