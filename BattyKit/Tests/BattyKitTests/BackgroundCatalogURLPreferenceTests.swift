// BackgroundCatalogURLPreferenceTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
final class BackgroundCatalogURLPreferenceTests {
    private let testDefaults = TestDefaults()
    private var defaults: UserDefaults { testDefaults.defaults }

    @MainActor deinit { testDefaults.tearDown() }

    @Test func storedURLsRoundTripInOrder() {
        let urls = ["https://b.example.com/c.json", "https://a.example.com/c.json"].map { URL(string: $0)! }
        SettingsPreference.setBackgroundCatalogURLs(urls, defaults: defaults)
        #expect(SettingsPreference.resolvedBackgroundCatalogURLs(defaults: defaults) == urls)
        #expect(defaults.array(forKey: SettingsPreference.backgroundCatalogURLsKey) as? [String] == urls.map(\.absoluteString))
    }

    @Test func malformedDuplicateAndBuiltInEntriesAreDropped() {
        defaults.set([
            "http://insecure.example.com/c.json",
            "not a url",
            "https://Example.com/c.json",
            "https://example.com/c.json",
            BackgroundCatalog.builtInURL.absoluteString,
        ], forKey: SettingsPreference.backgroundCatalogURLsKey)
        #expect(SettingsPreference.resolvedBackgroundCatalogURLs(defaults: defaults) == [URL(string: "https://example.com/c.json")!])
    }

    @Test func autoCheckDefaultsToOnAndCanBeTurnedOff() {
        #expect(SettingsPreference.resolvedBackgroundCatalogsAutoCheck(defaults: defaults))
        defaults.set(false, forKey: SettingsPreference.backgroundCatalogsAutoCheckKey)
        #expect(!SettingsPreference.resolvedBackgroundCatalogsAutoCheck(defaults: defaults))
    }
}
