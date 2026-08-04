// AppStateStoreBellDecisionHistoryTests.swift

import Foundation
import Testing
@testable import BattyKit

/// #0297 end-to-end: `AppStateStore.recordBellTick` /
/// `recordDesktopNotification` / `recordCLINotification` each route through
/// `postNotification`, which is the single production call site that
/// appends to `AppStateStore.bellDecisionHistory`. These tests exercise the
/// real store methods (rather than calling `BellDecisionHistory` directly,
/// which `BellDecisionHistoryTests` already covers in isolation) to prove
/// the wiring — the right trigger kind is captured for each of the three
/// real paths, a real suppression gate (session mute) shows up in the
/// captured outcome, and capture is unconditional (no toggle, unlike the
/// superseded round-1/2 designs).
@MainActor
struct AppStateStoreBellDecisionHistoryTests {

    @Test func recordBellTickCapturesTheBelTriggerKind() {
        let notifier = SpyBellNotifier()
        let store = AppStateStore(notifier: notifier)
        let session = store.sessions[0]
        let tabID = session.focusedPane.activeTabID

        session.focusedPane.activeTab?.terminal.terminalDidRingBell()
        store.recordBellTick(forTabID: tabID)

        #expect(store.bellDecisionHistory.records.count == 1)
        #expect(store.bellDecisionHistory.records[0].trigger == .bel)
    }

    @Test func recordDesktopNotificationCapturesTheOscNotificationTriggerKind() {
        let notifier = SpyBellNotifier()
        let store = AppStateStore(notifier: notifier)
        let session = store.sessions[0]
        let tabID = session.focusedPane.activeTabID

        session.focusedPane.activeTab?.terminal.terminalDidRequestDesktopNotification(
            title: "Build", body: "Succeeded"
        )
        store.recordDesktopNotification(forTabID: tabID)

        #expect(store.bellDecisionHistory.records.count == 1)
        #expect(store.bellDecisionHistory.records[0].trigger == .oscNotification)
    }

    @Test func recordCLINotificationCapturesTheCliNotificationTriggerKind() {
        let notifier = SpyBellNotifier()
        let store = AppStateStore(notifier: notifier)
        let tabID = store.sessions[0].focusedPane.activeTabID

        store.recordCLINotification(tabID: tabID, title: "Done", body: nil, playSound: false)

        #expect(store.bellDecisionHistory.records.count == 1)
        #expect(store.bellDecisionHistory.records[0].trigger == .cliNotification)
    }

    @Test func mutedSessionCapturesTheSessionMutedSuppressionReason() {
        let notifier = SpyBellNotifier()
        let store = AppStateStore(notifier: notifier)
        let session = store.sessions[0]
        session.notificationsMuted = true
        let tabID = session.focusedPane.activeTabID

        store.recordCLINotification(tabID: tabID, title: "Done", body: nil, playSound: false)

        #expect(store.bellDecisionHistory.records.count == 1)
        #expect(store.bellDecisionHistory.records[0].outcome == .suppressed(.sessionMuted))
        #expect(notifier.postedEntries.isEmpty, "sanity check: the real post path was suppressed too")
    }

    @Test func nilNotifierCapturesTheNilNotifierSuppressionReason() {
        let store = AppStateStore(notifier: nil)
        let tabID = store.sessions[0].focusedPane.activeTabID

        store.recordCLINotification(tabID: tabID, title: "Done", body: nil, playSound: false)

        #expect(store.bellDecisionHistory.records.count == 1)
        #expect(store.bellDecisionHistory.records[0].outcome == .suppressed(.nilNotifier))
    }

    /// Round-2 review's B2: the raw fields must be bounded at capture time,
    /// not just at format time, so the ring buffer can't retain unbounded
    /// text ×`BellDecisionHistory.capacity` for the process lifetime.
    /// `recordCLINotification`'s message has no length limit anywhere
    /// upstream (`AppStateStore.formatNotifyMessage` just joins title and
    /// body), so a long body is the direct way to exercise it end to end.
    @Test func capturedMessageIsTruncatedToMaxFieldLengthAtTheStore() {
        let notifier = SpyBellNotifier()
        let store = AppStateStore(notifier: notifier)
        let tabID = store.sessions[0].focusedPane.activeTabID
        let longBody = String(repeating: "x", count: BellDecisionFormat.maxFieldLength * 4)

        store.recordCLINotification(tabID: tabID, title: "Done", body: longBody, playSound: false)

        let captured = store.bellDecisionHistory.records[0]
        #expect(captured.message?.count == BellDecisionFormat.maxFieldLength)
        #expect(captured.hasMessage == true, "truncation must not flip a real message to hasMessage=false")
    }

    @Test func capturedSessionTitleAndTabLabelAreTruncatedToMaxFieldLengthAtTheStore() {
        let notifier = SpyBellNotifier()
        let store = AppStateStore(notifier: notifier)
        let session = store.sessions[0]
        session.title = String(repeating: "s", count: BellDecisionFormat.maxFieldLength * 4)
        let tab = session.focusedPane.activeTab!
        tab.titleOverride = String(repeating: "t", count: BellDecisionFormat.maxFieldLength * 4)
        let tabID = tab.id

        store.recordCLINotification(tabID: tabID, title: "Done", body: nil, playSound: false)

        let captured = store.bellDecisionHistory.records[0]
        #expect(captured.sessionTitle.count == BellDecisionFormat.maxFieldLength)
        #expect(captured.tabLabel.count == BellDecisionFormat.maxFieldLength)
    }

    @Test func captureIsUnconditionalWithNoSettingsGate() {
        // #0297's earlier designs (round 1/2) gated capture behind a
        // Settings toggle defaulting off in Prod. The user's redirect
        // dropped that entirely: an in-memory-only buffer has no privacy
        // question left to gate. This pins that a freshly constructed
        // store -- no preference touched, nothing enabled explicitly --
        // still captures on the very first bell.
        let notifier = SpyBellNotifier()
        let store = AppStateStore(notifier: notifier)
        let tabID = store.sessions[0].focusedPane.activeTabID

        store.recordCLINotification(tabID: tabID, title: "Done", body: nil, playSound: false)

        #expect(store.bellDecisionHistory.records.count == 1)
    }

    /// #0290's memory-footprint warning shares the Bell Feed via
    /// `BellFeedEntry.systemID` but is not a real-tab bell -- it posts
    /// through `BellNotifier.postFootprintWarning`, never through
    /// `postNotification`. The issue explicitly warned that a system entry
    /// conflated into this analysis would poison it, so this pins that
    /// `recordFootprintWarning` structurally never reaches
    /// `bellDecisionHistory`, not just that it doesn't happen to today.
    @Test func recordFootprintWarningNeverEntersTheBellDecisionHistory() {
        let notifier = SpyBellNotifier()
        let store = AppStateStore(notifier: notifier)

        store.recordFootprintWarning(footprintBytes: 5_000_000_000, step: 1)

        #expect(store.bellDecisionHistory.records.isEmpty, "the #0290 system entry must never be captured as a real-bell decision")
    }
}
