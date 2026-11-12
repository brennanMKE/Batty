// HostedFetchPolicyTests.swift

import Foundation
import Testing
@testable import BattyKit

struct HostedFetchPolicyTests {
    @Test func redirectToHTTPSIsAllowed() {
        #expect(HostedFetchPolicy.allowsRedirect(to: URL(string: "https://cdn.example.com/a.png"), count: 1) == nil)
    }

    @Test func redirectToHTTPIsRefused() {
        #expect(HostedFetchPolicy.allowsRedirect(to: URL(string: "http://cdn.example.com/a.png"), count: 1) == .insecureRedirect)
        #expect(HostedFetchPolicy.allowsRedirect(to: nil, count: 1) == .insecureRedirect)
    }

    @Test func sixthRedirectIsRefused() {
        let url = URL(string: "https://cdn.example.com/a.png")
        #expect(HostedFetchPolicy.allowsRedirect(to: url, count: 5) == nil)
        #expect(HostedFetchPolicy.allowsRedirect(to: url, count: 6) == .tooManyRedirects)
    }

    @Test func statusCodesMapToErrors() {
        #expect(HostedFetchPolicy.error(forStatus: 200) == nil)
        #expect(HostedFetchPolicy.error(forStatus: 304) == nil)
        #expect(HostedFetchPolicy.error(forStatus: 404) == .notFound)
        #expect(HostedFetchPolicy.error(forStatus: 503) == .server(503))
        #expect(HostedFetchPolicy.error(forStatus: 403) == .http(403))
        #expect(HostedFetchError.notFound.message(host: "batty.sstools.co") == "Not found (404)")
        #expect(HostedFetchError.unreachable.message(host: "batty.sstools.co") == "Can't reach batty.sstools.co")
    }

    @Test func urlErrorsMapToErrors() {
        #expect(HostedFetchPolicy.error(for: URLError(.notConnectedToInternet)) == .unreachable)
        #expect(HostedFetchPolicy.error(for: URLError(.cannotFindHost)) == .unreachable)
        #expect(HostedFetchPolicy.error(for: URLError(.serverCertificateUntrusted)) == .untrustedCertificate)
        #expect(HostedFetchPolicy.error(for: URLError(.secureConnectionFailed)) == .untrustedCertificate)
        #expect(HostedFetchPolicy.error(for: URLError(.timedOut)) == .timedOut)
        #expect(HostedFetchPolicy.error(for: URLError(.cancelled)) == .cancelled)
    }

    @Test func byteLimitCounterStopsPastTheLimit() {
        var counter = ByteLimitCounter(limit: 10)
        let first = counter.add(6)
        let second = counter.add(4)
        let third = counter.add(1)
        #expect(first)
        #expect(second)
        #expect(!third)
        #expect(counter.accepts(expectedLength: 10))
        #expect(!counter.accepts(expectedLength: 11))
        #expect(counter.accepts(expectedLength: nil))
    }
}
