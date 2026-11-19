// WebPreviewEngine.swift

import AppKit
import OSLog
import WebKit

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "WebPreviewEngine")

public enum WebPreviewEvent: Equatable {
    case state(url: URL?, title: String?, canGoBack: Bool, canGoForward: Bool, isLoading: Bool)
    case failed(String)
    case refused(URL)
    case openExternally(URL)
}

/// The web view behind a Web Preview Pane. A protocol so the Pane's
/// lifecycle tests run without WebKit.
@MainActor
public protocol WebPreviewEngine: AnyObject {
    var view: NSView { get }
    var events: ((WebPreviewEvent) -> Void)? { get set }
    func load(_ url: URL)
    func reload()
    func goBack()
    func goForward()
    func stopLoading()
    func setMediaSuspended(_ suspended: Bool)
    /// Drops delegates and observations and removes the view from its
    /// superview. Called only from `tearDown`, never from a SwiftUI callback.
    func invalidate()
}

/// Reports clicks so the Pane can take focus: a click inside a web view
/// never reaches SwiftUI's tap gesture.
public final class BattyPreviewWebView: WKWebView {
    public var onMouseDown: (() -> Void)?

    public override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }
}

@MainActor
public final class WKWebViewPreviewEngine: NSObject, WebPreviewEngine {
    public static let applicationName = "BattyPreview/1"

    public let webView: BattyPreviewWebView
    public var events: ((WebPreviewEvent) -> Void)?
    private var observations: [NSKeyValueObservation] = []

    public var view: NSView { webView }

    public override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.applicationNameForUserAgent = Self.applicationName
        webView = BattyPreviewWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        let publish: @Sendable (WKWebView) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.publishState() }
        }
        observations = [
            webView.observe(\.url) { view, _ in publish(view) },
            webView.observe(\.title) { view, _ in publish(view) },
            webView.observe(\.canGoBack) { view, _ in publish(view) },
            webView.observe(\.canGoForward) { view, _ in publish(view) },
            webView.observe(\.isLoading) { view, _ in publish(view) },
        ]
    }

    public var hasDelegates: Bool { webView.navigationDelegate != nil || webView.uiDelegate != nil }

    private func publishState() {
        events?(.state(url: webView.url, title: webView.title, canGoBack: webView.canGoBack, canGoForward: webView.canGoForward, isLoading: webView.isLoading))
    }

    public func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    public func reload() { webView.reload() }
    public func goBack() { webView.goBack() }
    public func goForward() { webView.goForward() }
    public func stopLoading() { webView.stopLoading() }

    public func setMediaSuspended(_ suspended: Bool) {
        webView.setAllMediaPlaybackSuspended(suspended, completionHandler: nil)
    }

    public func invalidate() {
        observations.forEach { $0.invalidate() }
        observations = []
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.onMouseDown = nil
        events = nil
        webView.removeFromSuperview()
    }

    /// `target=_blank` and `window.open` follow the top-level rules. Only a
    /// clicked link counts as the user's: `window.open` from script arrives
    /// as `.other` (and macOS lets script open windows by default), so it
    /// never sends the user's browser elsewhere.
    nonisolated static func newWindowDecision(url: URL, navigationType: WKNavigationType) -> WebPreviewURLPolicy.Decision {
        WebPreviewURLPolicy.decide(url: url, isMainFrame: true, isUserActivated: navigationType == .linkActivated)
    }

    fileprivate func decide(_ action: WKNavigationAction) -> WebPreviewURLPolicy.Decision {
        guard let url = action.request.url else { return .cancel }
        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        let decision = WebPreviewURLPolicy.decide(url: url, isMainFrame: isMainFrame, isUserActivated: action.navigationType == .linkActivated)
        switch decision {
        case .allow:
            break
        case .openExternally:
            events?(.openExternally(url))
        case .cancel:
            if isMainFrame {
                logger.info("cancelled navigation to \(url.absoluteString, privacy: .private)")
                events?(.refused(url))
            }
        }
        return decision
    }
}

extension WKWebViewPreviewEngine: WKNavigationDelegate, WKUIDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(decide(navigationAction) == .allow ? .allow : .cancel)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        report(error)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        report(error)
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        switch Self.newWindowDecision(url: url, navigationType: navigationAction.navigationType) {
        case .allow: webView.load(navigationAction.request)
        case .openExternally: events?(.openExternally(url))
        case .cancel: events?(.refused(url))
        }
        return nil
    }

    private func report(_ error: any Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        // WebKitErrorFrameLoadInterruptedByPolicyChange: our own cancel.
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
        events?(.failed(nsError.localizedDescription))
    }
}
