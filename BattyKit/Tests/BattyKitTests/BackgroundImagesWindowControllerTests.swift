// BackgroundImagesWindowControllerTests.swift

import AppKit
import Testing
@testable import BattyKit

@MainActor
struct BackgroundImagesWindowControllerTests {
    private let f: ProjectBackgroundFixture

    init() throws { f = try ProjectBackgroundFixture() }

    @Test func prepareReusesTheOneWindow() {
        let store = f.appStore()
        let controller = BackgroundImagesWindowController()
        let first = controller.prepare(store: store)
        #expect(controller.prepare(store: store) === first)
        #expect(first.identifier?.rawValue == BackgroundImagesWindowController.windowIdentifier)
        first.close()
        #expect(controller.window == nil)
    }

    @Test func becomingKeyPicksUpAUseChangedWhileTheWindowStayedOpen() async throws {
        let path = try await f.copy()
        let digest = try #require(TerminalBackgroundImageImporter.digest(ofPath: path))
        let store = f.appStore()
        let controller = BackgroundImagesWindowController()
        let window = controller.prepare(store: store)
        #expect(window.delegate === controller)

        let project = f.project(name: "Harbor", background: projectBackgroundValue(path: path))
        try store.projectStore.upsert(project)
        #expect(store.backgroundImages.uses[digest] == nil)

        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))

        #expect(store.backgroundImages.uses[digest] == [.project(id: project.id, name: "Harbor", isShared: false)])
        window.close()
    }

    @Test func becomingKeyChecksTheCatalogsOnceTheIntervalHasPassed() async throws {
        let store = f.appStore()
        let catalogURL = BackgroundCatalog.builtInURL
        try HostedCatalogServer(fetcher: f.catalogFetcher).serve(catalogURL)
        await store.backgroundImages.hosted.browseAppeared()
        let controller = BackgroundImagesWindowController()
        let window = controller.prepare(store: store)
        let note = Notification(name: NSWindow.didBecomeKeyNotification, object: window)

        controller.windowDidBecomeKey(note)
        await controller.appearCheck?.value
        #expect(f.catalogFetcher.count(catalogURL) == 1)

        _ = await f.clock.advance(by: .seconds(6 * 60))
        controller.windowDidBecomeKey(note)
        await controller.appearCheck?.value
        #expect(f.catalogFetcher.count(catalogURL) == 2)
        window.close()
    }

    @Test func becomingKeyBeforeTheFirstBrowseFetchesNothing() async throws {
        let store = f.appStore()
        try HostedCatalogServer(fetcher: f.catalogFetcher).serve(BackgroundCatalog.builtInURL)
        let controller = BackgroundImagesWindowController()
        let window = controller.prepare(store: store)
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        await controller.appearCheck?.value
        #expect(f.catalogFetcher.requests.isEmpty)
        window.close()
    }

    @Test func theWindowIsAuxiliaryNotContent() {
        let store = f.appStore()
        let controller = BackgroundImagesWindowController()
        let window = controller.prepare(store: store)
        store.keyWindowProvider = { window }
        #expect(store.auxiliaryWindowIsKey)
        window.close()
    }
}
