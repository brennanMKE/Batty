// FootprintMonitorIntegrationTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
private final class FootprintWarningSpyNotifier: BellNotifying {
    private(set) var postedFootprintWarnings: [(title: String, body: String, identifier: String)] = []

    func post(
        for entry: BellFeedEntry,
        sessionTitle: String,
        paneIndex: Int,
        tabLabel: String,
        playSound: Bool
    ) {}

    func postFootprintWarning(title: String, body: String, identifier: String) {
        postedFootprintWarnings.append((title, body, identifier))
    }
}

@MainActor
struct AppStateStoreFootprintWarningTests {

    @Test func recordFootprintWarningAddsAnUnseenSystemEntryWithFootprintAndSessionCount() {
        let notifier = FootprintWarningSpyNotifier()
        let store = AppStateStore(notifier: notifier)

        store.recordFootprintWarning(footprintBytes: 4_300_000_000, step: 1)

        guard let entry = store.bellFeed.entries.first else {
            Issue.record("Expected a Bell Feed entry")
            return
        }
        #expect(store.bellFeed.entries.count == 1)
        #expect(entry.seen == false)
        #expect(entry.sessionID == BellFeedEntry.systemID)
        #expect(entry.windowID == BellFeedEntry.systemID)
        #expect(entry.paneID == BellFeedEntry.systemID)
        #expect(entry.tabID == BellFeedEntry.systemID)
        // Session count comes from TerminalHostStore.shared, which the default
        // AppStateStore(notifier:) initializer never registers a tab with —
        // the message should still name a Terminal Session count (0) and a
        // formatted byte count, not silently drop either.
        #expect(entry.message?.contains("Terminal Session") == true)
        #expect(entry.message?.isEmpty == false)
    }

    @Test func recordFootprintWarningNotifiesWithMatchingIdentifier() {
        let notifier = FootprintWarningSpyNotifier()
        let store = AppStateStore(notifier: notifier)

        store.recordFootprintWarning(footprintBytes: 4_300_000_000, step: 1)

        guard let entry = store.bellFeed.entries.first else {
            Issue.record("Expected a Bell Feed entry")
            return
        }
        #expect(notifier.postedFootprintWarnings.count == 1)
        #expect(notifier.postedFootprintWarnings.first?.identifier == entry.id.uuidString)
        #expect(notifier.postedFootprintWarnings.first?.body == entry.message)
    }

    @Test func repeatedWarningsProduceIndependentEntries() {
        // recordFootprintWarning itself does no suppression — that's
        // FootprintWarningState's job, upstream in FootprintMonitor. This
        // just confirms the plumbing doesn't dedupe/overwrite on its own.
        let notifier = FootprintWarningSpyNotifier()
        let store = AppStateStore(notifier: notifier)

        store.recordFootprintWarning(footprintBytes: 4_300_000_000, step: 1)
        store.recordFootprintWarning(footprintBytes: 5_300_000_000, step: 2)

        #expect(store.bellFeed.entries.count == 2)
    }
}

@MainActor
struct FootprintMonitorTests {

    /// `limitBytesProvider` and `footprintBytesProvider` injection (rather
    /// than `UserDefaults` or the live process's real, constantly-if-slowly
    /// changing footprint) keeps these self-contained and deterministic.
    /// `UserDefaults.standard` is global process state, and Swift Testing
    /// runs test functions concurrently by default, so racing to set/remove
    /// the same preference key is flaky; the real footprint changing
    /// between two back-to-back `sampleOnce()` calls is exactly the kind of
    /// incidental growth this suppression rule has to be immune to, so
    /// asserting against it (rather than injecting a fixed value) doesn't
    /// actually constrain the rule. Each test here owns its own
    /// `FootprintMonitor` and its own closures — no shared mutable state
    /// with any other test.

    private static let fourGBLimit: UInt64 = 4_000_000_000

    @Test func sampleOnceDoesNotWarnUnderTheLimit() {
        let monitor = FootprintMonitor()
        monitor.limitBytesProvider = { Self.fourGBLimit }
        monitor.footprintBytesProvider = { 3_000_000_000 }
        var warned = false
        monitor.onWarn = { _, _ in warned = true }

        monitor.sampleOnce()

        #expect(warned == false)
    }

    @Test func sampleOnceWarnsOnceTheFootprintCrossesTheLimit() {
        let monitor = FootprintMonitor()
        monitor.limitBytesProvider = { Self.fourGBLimit }
        monitor.footprintBytesProvider = { 4_300_000_000 }
        var warnedBytes: UInt64?
        var warnedStep: Int?
        monitor.onWarn = { bytes, step in
            warnedBytes = bytes
            warnedStep = step
        }

        monitor.sampleOnce()

        #expect(warnedBytes == 4_300_000_000)
        #expect(warnedStep == 1)
    }

    @Test func sampleOnceDoesNotRepeatOnConsecutiveSamplesAtTheSameStep() {
        let monitor = FootprintMonitor()
        monitor.limitBytesProvider = { Self.fourGBLimit }
        monitor.footprintBytesProvider = { 4_300_000_000 }
        var warnCount = 0
        monitor.onWarn = { _, _ in warnCount += 1 }

        monitor.sampleOnce()
        monitor.sampleOnce()
        monitor.sampleOnce()

        #expect(warnCount == 1)
    }

    @Test func sampleOnceWarnsAgainOnANewStep() {
        let monitor = FootprintMonitor()
        monitor.limitBytesProvider = { Self.fourGBLimit }
        var bytes: UInt64 = 4_300_000_000
        monitor.footprintBytesProvider = { bytes }
        var warnCount = 0
        monitor.onWarn = { _, _ in warnCount += 1 }

        monitor.sampleOnce()
        bytes = 5_300_000_000 // one full stepBytes (limit/4 == 1 GB) further
        monitor.sampleOnce()

        #expect(warnCount == 2)
    }

    @Test func defaultLimitBytesProviderReadsTheRealPreference() {
        // One narrow, single-assertion check that the production default
        // isn't accidentally hardcoded — everything else in this suite
        // injects its own provider to stay independent of global UserDefaults
        // state.
        let monitor = FootprintMonitor()
        #expect(monitor.limitBytesProvider() == SettingsPreference.resolvedFootprintSoftLimitBytes())
    }

    @Test func defaultFootprintBytesProviderReadsTheRealFootprint() {
        let monitor = FootprintMonitor()
        #expect(monitor.footprintBytesProvider() != nil)
    }

    @Test func sampleOnceLogsAndSkipsWhenTheFootprintProviderFails() {
        let monitor = FootprintMonitor()
        monitor.limitBytesProvider = { 1 }
        monitor.footprintBytesProvider = { nil }
        var warned = false
        monitor.onWarn = { _, _ in warned = true }

        monitor.sampleOnce()

        #expect(warned == false)
    }
}
