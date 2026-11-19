// BackgroundPickerClickTests.swift

import Testing
@testable import BattyKit

struct BackgroundPickerClickTests {
    @Test func singleClickApplies() {
        #expect(BackgroundPickerClick.resolve(clickCount: 1, isDownloadingPendingPick: false) == .apply)
    }

    @Test func singleClickOnTheDownloadingPickCancelsIt() {
        #expect(BackgroundPickerClick.resolve(clickCount: 1, isDownloadingPendingPick: true) == .cancelDownload)
    }

    @Test func doubleClickAppliesAndClosesEvenWhileDownloading() {
        #expect(BackgroundPickerClick.resolve(clickCount: 2, isDownloadingPendingPick: true) == .applyAndClose)
        #expect(BackgroundPickerClick.resolve(clickCount: 2, isDownloadingPendingPick: false) == .applyAndClose)
    }

    @Test func moreClicksStillApplyAndClose() {
        #expect(BackgroundPickerClick.resolve(clickCount: 3, isDownloadingPendingPick: true) == .applyAndClose)
    }

    @Test func noClickCountCountsAsOneClick() {
        #expect(BackgroundPickerClick.resolve(clickCount: 0, isDownloadingPendingPick: false) == .apply)
        #expect(BackgroundPickerClick.resolve(clickCount: 0, isDownloadingPendingPick: true) == .cancelDownload)
    }
}
