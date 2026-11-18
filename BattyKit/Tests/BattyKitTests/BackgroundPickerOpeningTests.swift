// BackgroundPickerOpeningTests.swift

import Foundation
import Testing
@testable import BattyKit

struct BackgroundPickerOpeningTests {
    private let digest = String(repeating: "a", count: 64)
    private var path: String { "/tmp/Backgrounds/\(digest)/Sky.png" }
    private let url = URL(string: "https://batty.sstools.co/backgrounds/sky.png")!
    private let otherURL = URL(string: "https://batty.sstools.co/backgrounds/other.png")!

    private func record(_ url: URL) -> HostedImageRecord {
        HostedImageRecord(url: url, digest: digest, fetchedAt: Date(timeIntervalSince1970: 0))
    }

    private func cacheEntry(_ url: URL?) -> DownloadedImageEntry {
        DownloadedImageEntry(digest: digest, url: url, name: "Sky", bytes: 1, lastUsedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func noCurrentImageOpensBackgroundSetsWithNothingSelected() {
        let opening = BackgroundPickerOpening.resolve(currentPath: nil, hostedRecords: [record(url)], cacheEntries: [])
        #expect(opening == BackgroundPickerOpening(tab: .backgroundSets, hostedKey: nil, libraryDigest: nil))
    }

    @Test func pathOutsideADigestFolderOpensBackgroundSets() {
        let opening = BackgroundPickerOpening.resolve(currentPath: "/tmp/Pictures/Sky.png", hostedRecords: [], cacheEntries: [])
        #expect(opening == BackgroundPickerOpening(tab: .backgroundSets, hostedKey: nil, libraryDigest: nil))
    }

    @Test func hostedRecordOpensBackgroundSetsOnItsURL() {
        let opening = BackgroundPickerOpening.resolve(currentPath: path, hostedRecords: [record(url)], cacheEntries: [])
        #expect(opening == BackgroundPickerOpening(tab: .backgroundSets, hostedKey: HostedImageKey(url: url), libraryDigest: nil))
    }

    @Test func downloadedCacheEntryOpensBackgroundSetsOnItsURL() {
        let opening = BackgroundPickerOpening.resolve(currentPath: path, hostedRecords: [], cacheEntries: [cacheEntry(url)])
        #expect(opening == BackgroundPickerOpening(tab: .backgroundSets, hostedKey: HostedImageKey(url: url), libraryDigest: nil))
    }

    @Test func hostedRecordWinsOverACacheEntryWithTheSameDigest() {
        let opening = BackgroundPickerOpening.resolve(currentPath: path, hostedRecords: [record(url)], cacheEntries: [cacheEntry(otherURL)])
        #expect(opening.hostedKey == HostedImageKey(url: url))
    }

    @Test func cacheEntryWithoutAURLIsMyImages() {
        let opening = BackgroundPickerOpening.resolve(currentPath: path, hostedRecords: [], cacheEntries: [cacheEntry(nil)])
        #expect(opening == BackgroundPickerOpening(tab: .myImages, hostedKey: nil, libraryDigest: digest))
    }

    @Test func customDigestOpensMyImagesOnThatDigest() {
        let opening = BackgroundPickerOpening.resolve(currentPath: path, hostedRecords: [], cacheEntries: [])
        #expect(opening == BackgroundPickerOpening(tab: .myImages, hostedKey: nil, libraryDigest: digest))
    }

    @Test func contentsContainKeyOnlyOnceItsCatalogLoads() {
        let key = HostedImageKey(url: url)
        let image = HostedBackgroundImage(title: "Sky", full: url, thumbnail: url)
        let other = HostedBackgroundImage(title: "Other", full: otherURL, thumbnail: otherURL)
        func content(_ images: [HostedBackgroundImage]?) -> HostedCatalogContent {
            HostedCatalogContent(
                url: BackgroundCatalog.builtInURL,
                catalog: images.map { BackgroundCatalog(sets: [BackgroundSet(id: 0, name: "Set", images: $0)]) })
        }
        #expect(!BackgroundPickerOpening.contents([content(nil)], contain: key))
        #expect(BackgroundPickerOpening.contents([content([other, image])], contain: key))
        #expect(!BackgroundPickerOpening.contents([content([other])], contain: key))
    }
}
