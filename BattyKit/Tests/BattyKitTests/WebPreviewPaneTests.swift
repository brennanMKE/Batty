// WebPreviewPaneTests.swift

import AppKit
import BattyXPCCore
import Foundation
import Testing
import WebKit
@testable import BattyKit

@MainActor
final class FakeWebPreviewEngine: WebPreviewEngine {
    let view = NSView()
    var events: ((WebPreviewEvent) -> Void)?
    var loaded: [URL] = []
    var reloads = 0
    var mediaSuspended: [Bool] = []
    var stopped = 0
    var invalidated = 0

    func load(_ url: URL) { loaded.append(url) }
    func reload() { reloads += 1 }
    func goBack() {}
    func goForward() {}
    func stopLoading() { stopped += 1 }
    func setMediaSuspended(_ suspended: Bool) { mediaSuspended.append(suspended) }
    func invalidate() { invalidated += 1; events = nil }
}

nonisolated final class ObservationChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@MainActor
struct WebPreviewPaneContentTests {
    let url = URL(string: "http://127.0.0.1:52144/")!
    let broadcaster = StaticReloadBroadcaster()

    final class Engines {
        var made: [FakeWebPreviewEngine] = []
    }

    func content(engines: Engines, opened: (@MainActor (URL) -> Void)? = nil, source: (@MainActor (URL) -> StaticReloadBroadcaster?)? = nil) -> WebPreviewPaneContent {
        let broadcaster = broadcaster
        return WebPreviewPaneContent(
            url: url,
            reloadSource: source ?? { _ in broadcaster },
            opener: { opened?($0) },
            makeEngine: {
                let engine = FakeWebPreviewEngine()
                engines.made.append(engine)
                return engine
            })
    }

    @Test func createdHiddenMakesNoEngine() {
        let engines = Engines()
        let content = content(engines: engines)
        content.setUp(visible: false)
        #expect(engines.made.isEmpty)
        #expect(content.engineView == nil)
        #expect(!content.isActive)
        content.tearDown()
    }

    @Test func firstShowCreatesTheEngineAndLoadsTheURL() {
        let engines = Engines()
        let content = content(engines: engines)
        content.setUp(visible: false)
        content.setVisible(true)
        #expect(engines.made.count == 1)
        #expect(engines.made[0].loaded == [url])
        #expect(content.engineView === engines.made[0].view)
        #expect(content.isActive)
        content.tearDown()
    }

    @Test func hideUnmountsAndSuspendsMedia() {
        let engines = Engines()
        let content = content(engines: engines)
        content.setUp(visible: true)
        content.setVisible(false)
        #expect(!content.isActive)
        #expect(engines.made[0].mediaSuspended == [true])
        content.tearDown()
    }

    @Test func changeWhileVisibleReloadsOnce() {
        let engines = Engines()
        let content = content(engines: engines)
        content.setUp(visible: true)
        broadcaster.broadcast(at: Date())
        #expect(engines.made[0].reloads == 1)
        content.tearDown()
    }

    @Test func changeWhileHiddenReloadsOnceOnShow() {
        let engines = Engines()
        let content = content(engines: engines)
        content.setUp(visible: true)
        content.setVisible(false)
        broadcaster.broadcast(at: Date())
        broadcaster.broadcast(at: Date())
        #expect(engines.made[0].reloads == 0)
        content.setVisible(true)
        #expect(engines.made[0].reloads == 1)
        content.setVisible(false)
        content.setVisible(true)
        #expect(engines.made[0].reloads == 1)
        content.tearDown()
    }

    @Test func showWithoutAChangeDoesNotReload() {
        let engines = Engines()
        let content = content(engines: engines)
        content.setUp(visible: true)
        content.setVisible(false)
        content.setVisible(true)
        #expect(engines.made[0].reloads == 0)
        #expect(engines.made[0].loaded.count == 1)
        content.tearDown()
    }

    @Test func tearDownInvalidatesTheEngineAndUnsubscribesSynchronously() {
        let engines = Engines()
        let content = content(engines: engines)
        content.setUp(visible: true)
        #expect(broadcaster.observerCount == 1)
        content.tearDown()
        #expect(broadcaster.observerCount == 0)
        #expect(engines.made[0].stopped == 1)
        #expect(engines.made[0].invalidated == 1)
        #expect(content.engineView == nil)
        broadcaster.broadcast(at: Date())
        #expect(engines.made[0].reloads == 0)
    }

    @Test func navigateToANonLoopbackURLIsRefused() {
        let engines = Engines()
        let content = content(engines: engines)
        content.setUp(visible: true)
        #expect(!content.navigate(to: URL(string: "https://example.com/")!))
        #expect(content.url == url)
        #expect(engines.made[0].loaded == [url])
        let other = URL(string: "http://127.0.0.1:52144/sub/")!
        #expect(content.navigate(to: other))
        #expect(engines.made[0].loaded == [url, other])
        content.tearDown()
    }

    @Test func engineStateEventsUpdateObservedStateOnlyWhenChanged() {
        let engines = Engines()
        let content = content(engines: engines)
        content.setUp(visible: true)
        let changes = ObservationChangeCounter()
        func track() {
            withObservationTracking { _ = (content.title, content.canGoBack, content.isLoading) } onChange: { changes.increment() }
        }
        track()
        content.handle(.state(url: url, title: "One", canGoBack: true, canGoForward: false, isLoading: false))
        #expect(changes.value == 1)
        #expect(content.title == "One")
        #expect(content.canGoBack)
        track()
        content.handle(.state(url: url, title: "One", canGoBack: true, canGoForward: false, isLoading: false))
        #expect(changes.value == 1)
        content.tearDown()
    }

    @Test func refusedNavigationIsReported() {
        let engines = Engines()
        var opened: [URL] = []
        let content = content(engines: engines, opened: { opened.append($0) })
        content.setUp(visible: true)
        content.handle(.refused(URL(string: "http://evil.example/")!))
        #expect(content.lastError?.contains("evil.example") == true)
        content.handle(.openExternally(URL(string: "https://example.com/")!))
        #expect(opened == [URL(string: "https://example.com/")!])
        content.reload()
        #expect(content.lastError == nil)
        content.tearDown()
    }

    @Test func resubscribesWhenTheCommittedPortChanges() {
        let engines = Engines()
        let first = StaticReloadBroadcaster()
        let second = StaticReloadBroadcaster()
        let content = content(engines: engines, source: { $0.port == 52144 ? first : second })
        content.setUp(visible: true)
        #expect(first.observerCount == 1)
        content.handle(.state(url: URL(string: "http://127.0.0.1:52144/a.html")!, title: nil, canGoBack: false, canGoForward: false, isLoading: false))
        #expect(first.observerCount == 1)
        content.handle(.state(url: URL(string: "http://127.0.0.1:9000/")!, title: nil, canGoBack: true, canGoForward: false, isLoading: false))
        #expect(first.observerCount == 0)
        #expect(second.observerCount == 1)
        content.tearDown()
    }
}

@MainActor
struct WKWebViewPreviewEngineTests {
    @Test func configurationIsNonPersistentWithPreviewUserAgent() {
        let engine = WKWebViewPreviewEngine()
        let configuration = engine.webView.configuration
        #expect(!configuration.websiteDataStore.isPersistent)
        #expect(configuration.applicationNameForUserAgent == "BattyPreview/1")
        #expect(engine.webView.isInspectable)
        engine.invalidate()
    }

    @Test func invalidateRemovesFromSuperviewAndDropsDelegates() {
        let engine = WKWebViewPreviewEngine()
        let host = NSView()
        host.addSubview(engine.view)
        #expect(engine.hasDelegates)
        engine.invalidate()
        #expect(engine.view.superview == nil)
        #expect(!engine.hasDelegates)
    }
}

@MainActor
struct AppStateStoreWebPreviewTests {
    func fixture(serverPane: Bool = true) throws -> (StaticServerStoreFixture, Recorder) {
        let fixture = try StaticServerStoreFixture(serverPane: serverPane)
        let recorder = Recorder()
        fixture.store.makeWebPreviewContent = { url, source in
            WebPreviewPaneContent(url: url, reloadSource: source, opener: { _ in }, makeEngine: { FakeWebPreviewEngine() })
        }
        fixture.store.openURLInBrowser = { recorder.opened.append($0) }
        return (fixture, recorder)
    }

    final class Recorder {
        var opened: [URL] = []
    }

    func preview(_ fixture: StaticServerStoreFixture, _ url: String) -> Result<WebPreviewXPCResult, ServerXPCError> {
        fixture.store.openWebPreviewForXPC(WebPreviewRequest(paneID: fixture.callingPaneID, url: url))
    }

    func error<T>(_ result: Result<T, ServerXPCError>) -> ServerXPCError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    @Test func previewRefusesANonLoopbackURL() throws {
        let (fixture, _) = try fixture()
        #expect(error(preview(fixture, "https://example.com/")) == .previewURLNotAllowed)
        #expect(error(preview(fixture, "file:///etc/passwd")) == .previewURLNotAllowed)
        #expect(fixture.session.tree.allPanes.count == 1)
    }

    @Test func previewKeepsFocusOnTheCallingPane() throws {
        let (fixture, _) = try fixture()
        let caller = fixture.callingPaneID
        let result = try preview(fixture, "http://127.0.0.1:8083/").get()
        #expect(result.created)
        #expect(fixture.base.pane(result.paneID)?.kind == .webPreview)
        #expect(fixture.session.tree.focusedPaneID == caller)
    }

    @Test func previewReusesThePaneForTheSameOrigin() throws {
        let (fixture, _) = try fixture()
        let first = try preview(fixture, "http://127.0.0.1:8083/").get()
        let second = try preview(fixture, "http://127.0.0.1:8083/docs/").get()
        #expect(!second.created)
        #expect(second.paneID == first.paneID)
        #expect(second.content.url.absoluteString == "http://127.0.0.1:8083/docs/")
    }

    @Test func previewForANewOriginMakesANewPane() throws {
        let (fixture, _) = try fixture()
        let first = try preview(fixture, "http://127.0.0.1:8083/").get()
        let second = try preview(fixture, "http://localhost:8083/").get()
        #expect(second.created)
        #expect(second.paneID != first.paneID)
    }

    @Test func serveOpenPutsThePreviewBelowTheServerPane() async throws {
        let (fixture, recorder) = try fixture()
        let result = try await fixture.serve(open: true).get()
        let previewID = try #require(result.previewPaneID)
        #expect(fixture.base.pane(previewID)?.kind == .webPreview)
        #expect(splitDirectionBetween(result.paneID, previewID, in: fixture.session.tree.root) == .vertical)
        #expect(recorder.opened.isEmpty)
        #expect(fixture.store.serverReply(result).previewPaneID == previewID)
        let preview = try #require(fixture.base.pane(previewID)?.content as? WebPreviewPaneContent)
        #expect(preview.url == result.content.url)
    }

    @Test func serveOpenUsesTheBrowserWhenTheSettingSaysSo() async throws {
        let (fixture, recorder) = try fixture()
        fixture.base.defaults.set(ServedSiteOpenTarget.browser.rawValue, forKey: SettingsPreference.servedSiteOpenTargetKey)
        let result = try await fixture.serve(open: true).get()
        #expect(result.previewPaneID == nil)
        #expect(recorder.opened == [result.content.url])
    }

    @Test func openInBattyFromATerminalServerPaneWorks() throws {
        let (fixture, _) = try fixture()
        let server = try fixture.base.start()
        let content = server.content
        #expect(content.openPreview != nil)
        content.openPreview?()
        let previews = fixture.session.tree.allPanes.filter { $0.kind == .webPreview }
        #expect(previews.count == 1)
        #expect((previews.first?.content as? WebPreviewPaneContent)?.url == content.url)
    }

    @Test func previewFailsWithFlagOff() throws {
        let (fixture, _) = try fixture(serverPane: false)
        #expect(error(preview(fixture, "http://127.0.0.1:8083/")) == .flagOff)
    }

    @Test func previewReplyCarriesPaneAndURL() throws {
        let (fixture, _) = try fixture()
        let payload = try JSONEncoder().encode(WebPreviewRequest(paneID: fixture.callingPaneID, url: "http://127.0.0.1:8083/"))
        let response = AppXPCService.previewResponse(payload: payload, store: fixture.store)
        #expect(response.ok)
        let reply = try JSONDecoder().decode(WebPreviewReply.self, from: try #require(response.payload))
        #expect(reply.url == "http://127.0.0.1:8083/")
        #expect(reply.created)
        #expect(fixture.base.pane(reply.paneID)?.kind == .webPreview)
    }

    @Test func previewOfAnInAppServerReloadsOnItsChanges() async throws {
        let (fixture, _) = try fixture()
        let served = try await fixture.serve().get()
        let preview = try preview(fixture, served.content.url.absoluteString).get()
        let broadcaster = try #require(fixture.backend(served)?.broadcaster)
        preview.content.setVisible(true)
        #expect(broadcaster.observerCount == 1)
    }
}

@MainActor
private func splitDirectionBetween(_ a: UUID, _ b: UUID, in node: SplitTreeNode) -> SplitDirection? {
    guard case .split(_, let direction, _, let left, let right) = node else { return nil }
    let leftIDs = Set(left.allLeafPanes.map(\.id)), rightIDs = Set(right.allLeafPanes.map(\.id))
    if (leftIDs.contains(a) && rightIDs.contains(b)) || (leftIDs.contains(b) && rightIDs.contains(a)) { return direction }
    return splitDirectionBetween(a, b, in: left) ?? splitDirectionBetween(a, b, in: right)
}

@MainActor
struct ServerPaneInAppDisplayTests {
    @Test func inAppListeningReadsServing() {
        #expect(ServerPaneDisplay.stateText(.listening(pid: nil), isResponding: nil, kind: .inApp) == "Serving")
        #expect(ServerPaneDisplay.stateText(.stopped(exitCode: nil, reason: .requested), isResponding: nil, kind: .inApp) == "Stopped")
    }

    @Test func stopShownForInAppListening() {
        #expect(ServerPaneDisplay.showsStop(.listening(pid: nil), canStop: true, kind: .inApp))
        #expect(!ServerPaneDisplay.showsStop(.listening(pid: nil), canStop: true, kind: .external))
    }

    @Test func openInBattyShownOnlyForAllowedListeningURLs() async {
        let clock = TestClock()
        let signaller = FakeProcessSignaller()
        let table = FakeProcessTable(tabID: UUID())
        let allowed = ServerPaneContent(
            port: 1, url: URL(string: "http://127.0.0.1:1/"), backend: FakeInProcessBackend(), clock: clock,
            scanner: FakePortScanner(), signaller: signaller, processTable: table, opener: { _ in }
        )
        allowed.setUp(visible: true)
        await clock.waitForSleepers(1)
        #expect(!allowed.canOpenPreview)
        allowed.openPreview = {}
        await allowed.performTick()
        #expect(allowed.canOpenPreview)
        let foreign = ServerPaneContent(
            port: 1, url: URL(string: "http://example.com:1/"), backend: FakeInProcessBackend(), clock: clock,
            scanner: FakePortScanner(), signaller: signaller, processTable: table, opener: { _ in }
        )
        foreign.openPreview = {}
        foreign.setUp(visible: true)
        await foreign.performTick()
        #expect(foreign.state == .listening(pid: nil))
        #expect(!foreign.canOpenPreview)
        allowed.tearDown()
        foreign.tearDown()
        #expect(signaller.sent.isEmpty)
    }
}
