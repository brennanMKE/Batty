// WebPreviewPaneContent.swift

import AppKit
import Foundation
import Observation

/// A Web Preview Pane (#0649, `docs/design/web-preview-pane.md`). Owns its
/// engine; the view only mounts `engineView` while `isActive`.
@MainActor
@Observable
public final class WebPreviewPaneContent: PaneContentLifecycle {
    public private(set) var url: URL
    public private(set) var title: String?
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false
    public private(set) var isLoading = false
    public private(set) var lastError: String?
    public private(set) var isActive = false
    public private(set) var engineView: NSView?

    private let controller = PaneLifecycleController()
    public var lifecyclePhase: PaneLifecyclePhase { controller.phase }

    @ObservationIgnored private let makeEngine: @MainActor () -> WebPreviewEngine
    @ObservationIgnored private let reloadSource: @MainActor (URL) -> StaticReloadBroadcaster?
    @ObservationIgnored private let opener: @MainActor (URL) -> Void
    @ObservationIgnored private var engine: WebPreviewEngine?
    @ObservationIgnored private var subscription: (broadcaster: StaticReloadBroadcaster, id: UUID, port: Int)?
    @ObservationIgnored private var pendingReload = false

    public init(
        url: URL,
        reloadSource: @escaping @MainActor (URL) -> StaticReloadBroadcaster? = { _ in nil },
        opener: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        makeEngine: @escaping @MainActor () -> WebPreviewEngine = { WKWebViewPreviewEngine() }
    ) {
        self.url = url
        self.reloadSource = reloadSource
        self.opener = opener
        self.makeEngine = makeEngine
    }

    var hasEngine: Bool { engine != nil }
    var isSubscribed: Bool { subscription != nil }

    // MARK: - Lifecycle

    public func setUp(visible: Bool) {
        guard case .applied(_, .active) = controller.apply(.setUp(visible: visible)) else { return }
        activate()
    }

    public func setVisible(_ visible: Bool) {
        switch controller.apply(visible ? .show : .hide) {
        case .applied(_, .active): activate()
        case .applied(_, .suspended): deactivate()
        default: break
        }
    }

    public func tearDown() {
        guard case .applied = controller.apply(.tearDown) else { return }
        unsubscribe()
        engine?.stopLoading()
        engine?.invalidate()
        engine = nil
        if engineView != nil { engineView = nil }
        if isActive { isActive = false }
    }

    private func activate() {
        if let engine {
            engine.setMediaSuspended(false)
            if pendingReload {
                pendingReload = false
                engine.reload()
            }
        } else {
            let made = makeEngine()
            made.events = { [weak self] in self?.handle($0) }
            engine = made
            engineView = made.view
            pendingReload = false
            made.load(url)
        }
        if !isActive { isActive = true }
        subscribe(for: url)
    }

    private func deactivate() {
        if isActive { isActive = false }
        engine?.setMediaSuspended(true)
    }

    // MARK: - Reload link

    private func subscribe(for url: URL) {
        guard let port = WebPreviewURLPolicy.origin(of: url)?.port else {
            unsubscribe()
            return
        }
        if let subscription, subscription.port == port { return }
        unsubscribe()
        guard let broadcaster = reloadSource(url) else { return }
        let id = broadcaster.addObserver { [weak self] in self?.sourceChanged() }
        subscription = (broadcaster, id, port)
    }

    private func unsubscribe() {
        if let subscription { subscription.broadcaster.removeObserver(subscription.id) }
        subscription = nil
    }

    private func sourceChanged() {
        guard controller.phase != .tornDown else { return }
        if controller.phase == .active, let engine {
            engine.reload()
        } else {
            pendingReload = true
        }
    }

    // MARK: - Engine events

    func handle(_ event: WebPreviewEvent) {
        switch event {
        case .state(let newURL, let newTitle, let back, let forward, let loading):
            if let newURL, newURL != url {
                url = newURL
                subscribe(for: newURL)
            }
            if title != newTitle { title = newTitle }
            if canGoBack != back { canGoBack = back }
            if canGoForward != forward { canGoForward = forward }
            if isLoading != loading { isLoading = loading }
            if loading, lastError != nil { lastError = nil }
        case .failed(let message):
            if lastError != message { lastError = message }
        case .refused(let refused):
            let message = String(localized: "Web previews show only local pages; \(refused.absoluteString) was blocked.", comment: "Web Preview: a navigation was refused; the argument is the URL")
            if lastError != message { lastError = message }
        case .openExternally(let external):
            opener(external)
        }
    }

    // MARK: - Actions (event origin)

    public func goBack() { engine?.goBack() }
    public func goForward() { engine?.goForward() }

    public func reload() {
        if lastError != nil { lastError = nil }
        engine?.reload()
    }

    public func openInBrowser() { opener(url) }

    /// Loads `target` when it is a loopback page. Returns false, changing
    /// nothing, otherwise.
    @discardableResult
    public func navigate(to target: URL) -> Bool {
        guard WebPreviewURLPolicy.isAllowedTopLevel(target) else { return false }
        if url != target { url = target }
        if lastError != nil { lastError = nil }
        engine?.load(target)
        if controller.phase == .active { subscribe(for: target) }
        return true
    }
}
