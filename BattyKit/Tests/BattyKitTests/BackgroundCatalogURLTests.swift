// BackgroundCatalogURLTests.swift

import Foundation
import Testing
@testable import BattyKit

struct BackgroundCatalogURLTests {
    private func normalized(_ text: String) -> URL? {
        if case .success(let url) = BackgroundCatalogURLs.normalize(text) { return url }
        return nil
    }

    private func refusal(_ text: String) -> BackgroundCatalogURLRefusal? {
        if case .failure(let refusal) = BackgroundCatalogURLs.normalize(text) { return refusal }
        return nil
    }

    @Test func httpsURLIsAccepted() {
        #expect(normalized("https://example.com/catalog.json")?.absoluteString == "https://example.com/catalog.json")
    }

    @Test(arguments: ["http://example.com/catalog.json", "file:///tmp/catalog.json", "data:application/json,{}", "ftp://example.com/catalog.json"])
    func nonHTTPSSchemesAreRefused(_ text: String) {
        #expect(refusal(text) == .notHTTPS)
        #expect(BackgroundCatalogURLRefusal.notHTTPS.message == "Only https:// URLs can be added")
    }

    @Test func userInfoIsRefused() {
        #expect(refusal("https://user:pass@example.com/catalog.json") == .notHTTPS)
        #expect(refusal("https://user@example.com/catalog.json") == .notHTTPS)
    }

    @Test func missingHostIsRefused() {
        #expect(refusal("https:///catalog.json") == .notHTTPS)
        #expect(refusal("https:catalog.json") == .notHTTPS)
    }

    @Test func blankInputIsRefused() {
        #expect(refusal("") == .notHTTPS)
        #expect(refusal("   \n") == .notHTTPS)
    }

    @Test func normalizationLowercasesSchemeAndHostDropsPort443AndFragment() {
        #expect(normalized("HTTPS://Example.COM:443/Catalog.json#top")?.absoluteString == "https://example.com/Catalog.json")
    }

    @Test func normalizationKeepsPathCaseQueryAndOtherPorts() {
        #expect(normalized("https://example.com:8443/Sets/Catalog.JSON?v=A")?.absoluteString == "https://example.com:8443/Sets/Catalog.JSON?v=A")
    }

    @Test func surroundingWhitespaceIsTrimmed() {
        #expect(normalized("  https://example.com/catalog.json \n")?.absoluteString == "https://example.com/catalog.json")
    }

    @Test(arguments: ["localhost", "192.168.1.5", "nas.local"])
    func localAndPrivateHostsAreAllowed(_ host: String) {
        #expect(normalized("https://\(host)/catalog.json")?.host == host)
    }
}
