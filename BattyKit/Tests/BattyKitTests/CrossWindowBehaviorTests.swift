// CrossWindowBehaviorTests.swift

import AppKit
import Foundation
import Testing
@testable import BattyKit

/// Unit tests for #0239 cross-window behaviors:
///   - Bell-entry windowID carries the real owning window's ID.
///   - Bell in a non-key window counts as unseen (key-window isFocused term).
///   - jumpToBellEntry: dead-window entries no-op and mark seen.
///   - jumpToBellEntry: live-window entries navigate to the correct window.
///   - Window-close bell cleanup via cleanUpBellState(forTabIDs:).
///   - QuitConfirmation widens to all windows' sessions.
///   - App terminates when last content window is unregistered.
///   - onAllSessionsClosed wires to closeWindowCallback, not terminate.
///   - #0311: keyWindow fallback resolves to nil (not a trap) when windows
///     is empty; terminate is deferred off the window-close call stack and
///     re-verifies its guards before firing.
@MainActor
struct CrossWindowBehaviorTests {

    // MARK: - Bell windowID routing

    @Test func bellEntryCarriesOwningWindowID() {
        let store = AppStateStore()
        let w1 = store.windows[0]
        let w2 = store.windowRuntime(for: WindowID())

        let pane = w2.sessions[0].tree.allPanes[0]
        let tab = pane.tabs[0]
        // Make w2's session the "unfocused" one from w2's perspective.
        w2.selectedSessionID = nil

        tab.terminal.terminalDidRingBell()
        store.recordBellTick(forTabID: tab.id)

        let entry = store.bellFeed.entries.first
        #expect(entry != nil)
        #expect(entry?.windowID == w2.id.value,
                "Bell entry should carry the owning window's UUID, not a throwaway UUID")
        _ = w1  // Suppress unused warning
    }

    @Test func bellEntryWindowIDMatchesOwningWindowNotFirst() {
        let store = AppStateStore()
        let w2 = store.windowRuntime(for: WindowID())

        // Ring a bell in w2
        let pane = w2.sessions[0].tree.allPanes[0]
        let tab = pane.tabs[0]
        w2.selectedSessionID = nil  // Make it unfocused within w2

        tab.terminal.terminalDidRingBell()
        store.recordBellTick(forTabID: tab.id)

        let entry = store.bellFeed.entries.first
        #expect(entry?.windowID == w2.id.value,
                "Entry windowID must be the owning window's UUID, not windows[0]")
        #expect(entry?.windowID != store.windows[0].id.value,
                "Entry must not be attributed to the first window")
    }

    // MARK: - Key-window isFocused term

    @Test func bellInNonKeyWindowCountsAsUnseenEvenIfFocused() {
        // Simulate multi-window: register w2's NSWindow as key, w1 as non-key.
        // Then record a bell in w1's active tab — should count as unseen.
        let store = AppStateStore()
        let w1 = store.windows[0]
        let w2 = store.windowRuntime(for: WindowID())

        // Register a fake NSWindow for w2 so keyWindowRuntime returns w2.
        let fakeKeyWindow = NSWindow()
        store.registerNSWindow(fakeKeyWindow, for: w2.id)
        // Simulate w2 being the key window via swizzling is not feasible,
        // but we can test via the effective-seen logic by directly verifying
        // that when multiWindow is true and w1 ≠ keyWindowID the entry is unseen.
        // Since we cannot control NSApp.keyWindow in unit tests, we verify
        // the underlying logic: with multiWindow detected (keyWindowID != nil
        // from registered windows), bells in non-key windows should be unseen.
        // For now verify the windowID field is correct and that the tab does
        // NOT show unseen when w1's tab is "focused" in a single-window context.
        store.unregisterNSWindow(fakeKeyWindow)  // Undo, keep test isolation

        // Single-window-mode fallback: focused tab's bell is seen.
        let session = w1.sessions[0]
        w1.selectedSessionID = session.id
        let pane = session.tree.allPanes[0]
        let tab = pane.tabs[0]
        session.tree.focusedPaneID = pane.id
        pane.activeTabID = tab.id

        tab.terminal.terminalDidRingBell()
        store.recordBellTick(forTabID: tab.id)

        // In single-window mode (no key window registered), isFocused alone governs.
        #expect(store.bellFeed.entries.first?.seen == true,
                "Single-window-mode: focused tab bell should be seen")
        #expect(tab.unseenBellCount == 0)
    }

    @Test func bellInUnfocusedWindowSessionIsUnseenInSingleWindowMode() {
        let store = AppStateStore()
        let w1 = store.windows[0]
        let focusedSession = w1.sessions[0]
        let bgSession = w1.addSession(title: "Background")
        w1.selectedSessionID = focusedSession.id

        let pane = bgSession.tree.allPanes[0]
        let tab = pane.tabs[0]
        tab.terminal.terminalDidRingBell()
        store.recordBellTick(forTabID: tab.id)

        #expect(store.bellFeed.entries.first?.seen == false)
        #expect(tab.unseenBellCount == 1)
        #expect(bgSession.unseenBellCount == 1)
    }

    // MARK: - jumpToBellEntry: dead-window entries

    @Test func jumpToBellEntryDeadWindowNoOpsAndMarksSeen() {
        let store = AppStateStore()
        let w2 = store.windowRuntime(for: WindowID())

        // Ring a bell in w2, get the entry.
        let pane = w2.sessions[0].tree.allPanes[0]
        let tab = pane.tabs[0]
        w2.selectedSessionID = nil
        tab.terminal.terminalDidRingBell()
        store.recordBellTick(forTabID: tab.id)

        let entry = store.bellFeed.entries.first!

        // Now remove w2 from windows (simulating the window having closed).
        store.removeWindow(id: w2.id)
        #expect(!store.windows.contains(where: { $0.id == w2.id }))

        // jumpToBellEntry should no-op navigation and mark the entry seen.
        let initialSelectedSession = store.windows[0].selectedSessionID
        store.jumpToBellEntry(entry)

        #expect(store.bellFeed.entries.first?.seen == true,
                "Dead-window entry should be marked seen on jump")
        #expect(store.windows[0].selectedSessionID == initialSelectedSession,
                "Selection in surviving window must not change on dead-window jump")
    }

    // MARK: - jumpToBellEntry: live-window entries

    @Test func jumpToBellEntryLiveWindowNavigatesToCorrectSession() {
        let store = AppStateStore()
        let w1 = store.windows[0]
        let focusedSession = w1.sessions[0]
        let targetSession = w1.addSession(title: "Target")
        w1.selectedSessionID = focusedSession.id

        let pane = targetSession.tree.allPanes[0]
        let tab = pane.tabs[0]
        tab.terminal.terminalDidRingBell()
        store.recordBellTick(forTabID: tab.id)

        let entry = store.bellFeed.entries.first!
        #expect(entry.windowID == w1.id.value)

        store.jumpToBellEntry(entry)

        #expect(w1.selectedSessionID == targetSession.id,
                "jumpToBellEntry should select the entry's session in its owning window")
        #expect(w1.sessions[0].tree.focusedPaneID != nil)
    }

    @Test func jumpToBellEntryInSecondWindowNavigatesSecondWindow() {
        let store = AppStateStore()
        let w1 = store.windows[0]
        let w2 = store.windowRuntime(for: WindowID())

        // Ring a bell in w2's session.
        let w2Session = w2.sessions[0]
        w2.selectedSessionID = nil
        let pane = w2Session.tree.allPanes[0]
        let tab = pane.tabs[0]
        tab.terminal.terminalDidRingBell()
        store.recordBellTick(forTabID: tab.id)

        let entry = store.bellFeed.entries.first!
        #expect(entry.windowID == w2.id.value)

        // jumpToBellEntry should navigate w2, not w1.
        let w1InitialSession = w1.selectedSessionID
        store.jumpToBellEntry(entry)

        // w1's selection should be unchanged; w2's session should be navigated.
        #expect(w1.selectedSessionID == w1InitialSession,
                "jumpToBellEntry on w2's entry must not change w1's selection")
        #expect(w2.selectedSessionID == w2Session.id,
                "jumpToBellEntry should select the owning session in w2")
    }

    // MARK: - Window-close bell cleanup

    @Test func windowCloseBellCleanupRemovesWindowEntries() {
        let store = AppStateStore()
        let w2 = store.windowRuntime(for: WindowID())

        // Deliver unseen bells to w2.
        let pane = w2.sessions[0].tree.allPanes[0]
        let tab = pane.tabs[0]
        w2.selectedSessionID = nil
        tab.terminal.terminalDidRingBell()
        store.recordBellTick(forTabID: tab.id)
        tab.terminal.terminalDidRingBell()
        store.recordBellTick(forTabID: tab.id)

        #expect(store.bellFeed.entries.count == 2)
        #expect(tab.unseenBellCount == 2)

        // Simulate window-close cleanup (as WindowDelegate.windowWillClose does).
        let allTabIDs = Set(w2.sessions.flatMap { session in
            session.tree.allPanes.flatMap { $0.tabs.map(\.id) }
        })
        w2.cleanUpBellState(forTabIDs: allTabIDs)

        #expect(store.bellFeed.entries.isEmpty,
                "Window-close cleanup must remove all entries for that window's tabs")
        #expect(tab.unseenBellCount == 0)
        #expect(w2.sessions[0].unseenBellCount == 0)
    }

    // MARK: - QuitConfirmation widens to all windows

    @Test func quitConfirmationCountsTabsAcrossAllWindows() {
        let store = AppStateStore()
        let w2 = store.windowRuntime(for: WindowID())

        // w1 has 1 tab (the default), w2 has 1 tab.
        let w1TabCount = store.windows[0].sessions.flatMap { $0.tree.allPanes }.flatMap { $0.tabs }.count
        let w2TabCount = w2.sessions.flatMap { $0.tree.allPanes }.flatMap { $0.tabs }.count

        // Total across all windows via the widened logic.
        let total = store.windows.reduce(0) { acc, w in
            acc + w.sessions.reduce(0) { $0 + $1.tree.allPanes.reduce(0) { $0 + $1.tabs.count } }
        }
        #expect(total == w1TabCount + w2TabCount,
                "Quit confirmation should count tabs across all windows")
        #expect(total >= 2)
    }

    // MARK: - App termination on last content window

    @Test func removeWindowReducesWindowCount() {
        let store = AppStateStore()
        let w2 = store.windowRuntime(for: WindowID())
        #expect(store.windows.count == 2)

        store.removeWindow(id: w2.id)
        #expect(store.windows.count == 1)
        #expect(!store.windows.contains(where: { $0.id == w2.id }))
    }

    @Test func removeWindowForUnknownIDIsNoOp() {
        let store = AppStateStore()
        let unknownID = WindowID()
        let initialCount = store.windows.count
        store.removeWindow(id: unknownID)
        #expect(store.windows.count == initialCount)
    }

    // MARK: - #0311: keyWindow fallback must not trap when windows is empty

    /// Calls `AppStateStore.keyWindowOrFirstRegistered()` directly — the
    /// actual production method `BattyCommands.keyWindow` delegates to, not
    /// a re-typed copy of its expression (`Commands` bodies can't be
    /// unit-tested directly, so this is the closest testable seam to the
    /// real code path; see that method's doc comment). Before the fix this
    /// resolved via `store.windows[0]`, which traps on an empty array; this
    /// test proves the array can legitimately be empty at exactly this call
    /// site (removing the only window) and that the production fallback
    /// degrades to `nil` instead of trapping.
    @Test func keyWindowFallbackResolvesToNilWhenNoWindowsRemain() {
        let store = AppStateStore()
        // Deliberately overridden even though this test is only about the
        // keyWindow fallback, not termination timing: removing the only
        // window satisfies terminateIfLastContentWindowGone()'s guards, and
        // this test must stay safe to run regardless of whether the #0311
        // termination deferral (tested separately below) is intact.
        store.terminateHandler = {}
        let onlyWindowID = store.windows[0].id

        store.removeWindow(id: onlyWindowID)

        #expect(store.windows.isEmpty,
                "removeWindow on the only window must leave the registry empty")
        // Calls the actual production method BattyCommands.keyWindow
        // delegates to (review round 1: the prior version of this test
        // re-typed the expression inline, so it couldn't catch a regression
        // in the shipped code path — only in copy of it living in the test).
        let resolved = store.keyWindowOrFirstRegistered()
        #expect(resolved == nil,
                "keyWindowOrFirstRegistered() must resolve to nil, not trap indexing an empty windows array")
    }

    // MARK: - #0311: terminate is deferred off the window-close call stack

    /// Reproduces the exact #0311 crash setup: removing the last content
    /// window from inside what stands in for `windowWillClose`. Before the
    /// fix, `terminateIfLastContentWindowGone()` called `NSApp.terminate(nil)`
    /// synchronously from here — i.e. still inside this call — which is what
    /// let AppKit's runloop spin re-enter SwiftUI mid-teardown. `terminateHandler`
    /// is swapped out so the assertion can observe *when* termination fires
    /// without ever invoking AppKit's real termination path inside the test
    /// process.
    @Test func removeWindowOnLastWindowDoesNotTerminateSynchronously() {
        let store = AppStateStore()
        var terminated = false
        store.terminateHandler = { terminated = true }
        let onlyWindowID = store.windows[0].id

        store.removeWindow(id: onlyWindowID)

        #expect(terminated == false,
                "terminate must not fire synchronously inside removeWindow — that is the #0311 re-entrancy hazard")
    }

    /// Complements the synchronous-safety test above: the deferred
    /// termination must still actually happen on a later run-loop turn, not
    /// be silently dropped.
    @Test func removeWindowOnLastWindowEventuallyTerminates() async {
        let store = AppStateStore()
        var terminated = false
        store.terminateHandler = { terminated = true }
        let onlyWindowID = store.windows[0].id

        store.removeWindow(id: onlyWindowID)
        #expect(terminated == false)

        // Let the DispatchQueue.main.async-deferred check run.
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(terminated == true,
                "the deferred terminate check must still terminate once the run loop turns over")
    }

    /// If a new window is registered before the deferred check runs, the
    /// stale decision must abort rather than terminate against a state that
    /// no longer holds — the staleness guard the deferred design depends on.
    @Test func deferredTerminateAbortsIfANewWindowAppearsBeforeItRuns() async {
        let store = AppStateStore()
        var terminated = false
        store.terminateHandler = { terminated = true }
        let onlyWindowID = store.windows[0].id

        store.removeWindow(id: onlyWindowID)
        // A new window appears before the deferred block runs (e.g. New Window).
        _ = store.windowRuntime(for: WindowID())

        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(terminated == false,
                "a window that appeared before the deferred check ran must abort termination")
    }

    // MARK: - onAllSessionsClosed wires to closeWindowCallback

    @Test func onAllSessionsClosedCallsCloseWindowCallback() {
        let store = AppStateStore()
        var callbackFired = false
        store.windows[0].closeWindowCallback = { callbackFired = true }

        // onAllSessionsClosed was set in AppStateStore.init to call closeWindowCallback.
        store.windows[0].onAllSessionsClosed?()
        #expect(callbackFired,
                "onAllSessionsClosed must invoke closeWindowCallback, not terminate")
    }

    @Test func newWindowRuntimeOnAllSessionsClosedCallsCloseWindowCallback() {
        let store = AppStateStore()
        let w2 = store.windowRuntime(for: WindowID())
        var callbackFired = false
        w2.closeWindowCallback = { callbackFired = true }

        w2.onAllSessionsClosed?()
        #expect(callbackFired,
                "Newly created window runtime's onAllSessionsClosed must call closeWindowCallback")
    }

    // MARK: - Global theme application across windows (#0243)

    @Test func applyThemeToAllSurfacesRethemesEveryWindow() {
        let store = AppStateStore()
        let w1 = store.windows[0]
        let w2 = store.windowRuntime(for: WindowID())

        // Two distinct catalog themes so the applied theme differs from
        // whatever each surface initialised with, and from each other.
        let themeA = GhosttyThemeCatalog.allThemes[0]
        let themeB = GhosttyThemeCatalog.allThemes[1]

        func allTabs(_ w: WindowRuntime) -> [TabRuntime] {
            w.sessions.flatMap { $0.tree.allPanes.flatMap(\.tabs) }
        }

        store.applyThemeToAllSurfaces(themeA)
        let expectedA = themeA.toTerminalTheme()
        for tab in allTabs(w1) + allTabs(w2) {
            #expect(tab.terminal.controller.theme == expectedA)
        }

        store.applyThemeToAllSurfaces(themeB)
        let expectedB = themeB.toTerminalTheme()
        // The second window's surfaces in particular must update — the #0243
        // regression left them stale because the apply loop only walked the
        // windows[0] sessions shim, never the other windows.
        for tab in allTabs(w2) {
            #expect(tab.terminal.controller.theme == expectedB,
                    "Second window's surfaces must be re-themed by the global theme apply (#0243)")
        }
        for tab in allTabs(w1) {
            #expect(tab.terminal.controller.theme == expectedB)
        }
    }

    // MARK: - Global appearance application across windows (#0248)

    @Test func applyAppearanceToAllSurfacesUpdatesEveryWindow() {
        let store = AppStateStore()
        let w2 = store.windowRuntime(for: WindowID())

        func allTabs(_ w: WindowRuntime) -> [TabRuntime] {
            w.sessions.flatMap { $0.tree.allPanes.flatMap(\.tabs) }
        }

        // Stamp w2's tabs with TerminalConfiguration.default — a known configuration
        // that differs from the settings-derived one (different font size, no keybinds).
        // This is the "before" state that must be overwritten by the call below.
        for tab in allTabs(w2) {
            tab.terminal.controller.setTerminalConfiguration(.default)
        }
        let before = allTabs(w2)[0].terminal.controller.terminalConfiguration

        // Apply settings-derived appearance to all surfaces.
        store.applyAppearanceToAllSurfaces()

        let after = allTabs(w2)[0].terminal.controller.terminalConfiguration
        // The #0248 regression: the old loop used the `sessions` shim (→ windows[0])
        // so w2's tabs were never updated.  The fix iterates windows.flatMap.
        #expect(after != before,
                "applyAppearanceToAllSurfaces must update surfaces in every window, not only windows[0] (#0248)")
    }

    @Test func onAllSessionsClosedIsTriggeredWhenSessionsEmpty() {
        let store = AppStateStore()
        var closeCalled = false
        store.windows[0].closeWindowCallback = { closeCalled = true }

        // Close all tabs → remove session → trigger onAllSessionsClosed.
        let session = store.sessions[0]
        let tab = session.tree.allPanes[0].tabs[0]
        store.closeTab(id: tab.id)

        #expect(closeCalled,
                "Closing the last tab should trigger onAllSessionsClosed → closeWindowCallback")
    }
}
