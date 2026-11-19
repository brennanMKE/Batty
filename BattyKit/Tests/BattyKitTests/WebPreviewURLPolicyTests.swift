// WebPreviewURLPolicyTests.swift

import Foundation
import Testing
import BattyXPCCore
import WebKit
@testable import BattyKit

nonisolated struct WebPreviewURLPolicyTests {
    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test func allowsLoopbackHTTPAndHTTPS() {
        #expect(WebPreviewURLPolicy.isAllowedTopLevel(url("http://127.0.0.1:8083/")))
        #expect(WebPreviewURLPolicy.isAllowedTopLevel(url("http://localhost:3000/a/b?c=1")))
        #expect(WebPreviewURLPolicy.isAllowedTopLevel(url("https://localhost/")))
        #expect(WebPreviewURLPolicy.isAllowedTopLevel(url("HTTP://LOCALHOST:80/")))
    }

    @Test func allowsBracketedIPv6Loopback() {
        #expect(WebPreviewURLPolicy.isAllowedTopLevel(url("http://[::1]:8080/")))
    }

    @Test func refusesLookalikeHosts() {
        #expect(!WebPreviewURLPolicy.isAllowedTopLevel(url("http://127.0.0.1.evil.com/")))
        #expect(!WebPreviewURLPolicy.isAllowedTopLevel(url("http://localhost.evil.com/")))
        #expect(!WebPreviewURLPolicy.isAllowedTopLevel(url("http://evil.com/?h=localhost")))
        #expect(!WebPreviewURLPolicy.isAllowedTopLevel(url("http://127.0.0.2/")))
        #expect(!WebPreviewURLPolicy.isAllowedTopLevel(url("https://example.com/")))
    }

    @Test func refusesFileURLs() {
        #expect(!WebPreviewURLPolicy.isAllowedTopLevel(url("file:///etc/passwd")))
        #expect(WebPreviewURLPolicy.decide(url: url("file:///etc/passwd"), isMainFrame: true, isUserActivated: true) == .cancel)
    }

    @Test func externalLinkClickedByUserOpensInBrowser() {
        #expect(WebPreviewURLPolicy.decide(url: url("https://example.com/"), isMainFrame: true, isUserActivated: true) == .openExternally)
    }

    @Test func externalScriptNavigationIsCancelled() {
        #expect(WebPreviewURLPolicy.decide(url: url("https://example.com/"), isMainFrame: true, isUserActivated: false) == .cancel)
    }

    @Test func subframeFromACDNIsAllowed() {
        #expect(WebPreviewURLPolicy.decide(url: url("https://cdnjs.cloudflare.com/x.js"), isMainFrame: false, isUserActivated: false) == .allow)
    }

    @Test func subframeFileURLIsRefused() {
        #expect(WebPreviewURLPolicy.decide(url: url("file:///tmp/x.html"), isMainFrame: false, isUserActivated: false) == .cancel)
    }

    @Test func aboutBlankIsAllowed() {
        #expect(WebPreviewURLPolicy.isAllowedTopLevel(url("about:blank")))
        #expect(WebPreviewURLPolicy.decide(url: url("about:blank"), isMainFrame: true, isUserActivated: false) == .allow)
    }

    @Test func originFillsDefaultPorts() {
        #expect(WebPreviewURLPolicy.origin(of: url("http://localhost/"))?.port == 80)
        #expect(WebPreviewURLPolicy.origin(of: url("https://localhost/"))?.port == 443)
        #expect(WebPreviewURLPolicy.origin(of: url("http://127.0.0.1:8083/a")) == WebPreviewURLPolicy.origin(of: url("http://127.0.0.1:8083/b")))
        #expect(WebPreviewURLPolicy.origin(of: url("about:blank")) == nil)
    }

    @Test func newWindowFromAClickedExternalLinkOpensInBrowser() {
        #expect(WKWebViewPreviewEngine.newWindowDecision(url: url("https://example.com/"), navigationType: .linkActivated) == .openExternally)
    }

    @Test func newWindowFromScriptToAnExternalURLIsRefused() {
        #expect(WKWebViewPreviewEngine.newWindowDecision(url: url("https://example.com/"), navigationType: .other) == .cancel)
        #expect(WKWebViewPreviewEngine.newWindowDecision(url: url("http://127.0.0.1.evil.com/"), navigationType: .other) == .cancel)
        #expect(WKWebViewPreviewEngine.newWindowDecision(url: url("https://example.com/"), navigationType: .formSubmitted) == .cancel)
    }

    @Test func newWindowToLoopbackLoadsInThePreviewEitherWay() {
        #expect(WKWebViewPreviewEngine.newWindowDecision(url: url("http://127.0.0.1:8083/a.html"), navigationType: .linkActivated) == .allow)
        #expect(WKWebViewPreviewEngine.newWindowDecision(url: url("http://localhost:3000/"), navigationType: .other) == .allow)
    }

    @Test func newWindowToAFileURLIsRefusedEvenWhenClicked() {
        #expect(WKWebViewPreviewEngine.newWindowDecision(url: url("file:///etc/passwd"), navigationType: .linkActivated) == .cancel)
    }
}
