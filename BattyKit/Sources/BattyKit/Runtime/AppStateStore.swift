// AppStateStore.swift

import AppKit
import Foundation
import Observation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "AppStateStore")

@Observable
public final class AppStateStore {
    public static let shared = AppStateStore()

    // MARK: - Global services (cross-window)

    public let bellFeed: BellFeedStore
    /// #0297: in-memory ring buffer of the most recent bell/notification
    /// decisions, for the Settings > Advanced > Diagnostics export UI
    /// (`BellDecisionExportRow`). See `BellDecisionHistory`'s type doc
    /// comment for why this collects unconditionally rather than behind a
    /// toggle. Internal, not `public`, like `BellDecisionHistory` itself —
    /// every consumer (this file, `SettingsView.swift`) lives inside
    /// `BattyKit`.
    let bellDecisionHistory = BellDecisionHistory()
    public let nameCache: SessionNameCache
    public let themeChrome: ThemeChrome
    /// Owns the footprint sampling timer (#0290). Constructed here but never
    /// started by `init` — `start()` is production-only wiring
    /// (`BattyAppDelegate`), so constructing an `AppStateStore` on its own
    /// never spins up a background sampling loop.
    @ObservationIgnored public let footprintMonitor = FootprintMonitor()
    /// Set once, at construction. `AppStateStore.shared` is created on the
    /// first access early in app startup (`BattyApp`'s `WindowGroup`
    /// `defaultValue`), so this closely approximates process launch time —
    /// good enough for `statusPayload()`'s `uptimeSeconds` without needing a
    /// kernel-level process-start-time lookup.
    public let launchDate = Date()
    @ObservationIgnored public var notifier: BellNotifying?
    /// Called when `removeSession` empties the window's `sessions`. Nil in
    /// unit tests; the app delegate sets this to terminate the process.
    /// Forwarded to `windows[0].onAllSessionsClosed`.
    /// Called when `removeSession` empties the **first** window's `sessions`.
    /// Forwarded to `windows[0].onAllSessionsClosed` for backward compat with
    /// the single-window era. `#0239`: each window now has its own
    /// `onAllSessionsClosed` closure that closes the window instead of
    /// terminating the app; `BattyApp` wires this shim to the app-level
    /// hook that quits when the last content window has been closed.
    @ObservationIgnored public var onAllSessionsClosed: (() -> Void)? {
        get { windows[0].onAllSessionsClosed }
        set { windows[0].onAllSessionsClosed = newValue }
    }
    /// AI fallback for session auto-naming (#0231). Nil disables the AI
    /// step entirely — the deterministic chain behaves exactly as before.
    /// The app delegate wires `FoundationModelsNameSuggester.makeIfAvailable()`.
    @ObservationIgnored public var nameSuggester: SessionNameSuggesting?
    /// AI notification summarizer (#0246). Nil disables summarization. The
    /// app delegate wires `FoundationModelsNotificationSummarizer.makeIfAvailable()`.
    @ObservationIgnored public var notificationSummarizer: NotificationSummarizing?
    /// Called by `BattyShortcuts` (the NSEvent-monitor path) to open a new
    /// content window. The app delegate wires this to SwiftUI's captured
    /// `OpenWindowAction` — same wiring style as `onAllSessionsClosed`. Nil
    /// in unit tests and before the delegate sets it.
    @ObservationIgnored public var openWindowAction: (() -> Void)?
    /// NSWindow → WindowID mapping. Populated from each window's view tree
    /// (via `WindowIDRegistrar`) so `BattyShortcuts` can identify the key
    /// window's `WindowRuntime` without relying on window-title heuristics.
    /// `@ObservationIgnored` — populated from AppKit callbacks, not from
    /// SwiftUI-update code (the #0229 hazard class).
    @ObservationIgnored private var nsWindowMap: [ObjectIdentifier: WindowID] = [:]
    /// Actuates app termination once `terminateIfLastContentWindowGone`
    /// decides no content windows remain (#0311). Defaults to the real
    /// `NSApp.terminate(nil)`. Tests override this so `removeWindow`/
    /// `unregisterNSWindow` can be exercised on the last window without ever
    /// invoking AppKit's real termination path — which is neither safe nor
    /// meaningful inside `swift test`/`xcodebuild test`.
    @ObservationIgnored public var terminateHandler: () -> Void = { NSApp.terminate(nil) }
    /// Guards against scheduling more than one deferred termination check at
    /// once (#0311) — `windowWillClose` calls both `unregisterNSWindow` and
    /// `removeWindow` synchronously in the same teardown, and either can
    /// satisfy `terminateIfLastContentWindowGone`'s guards first.
    @ObservationIgnored private var terminationScheduled = false
    /// One in-flight AI naming request per session, keyed by session id and
    /// tagged with the cwd it was issued for so a repeat report of the same
    /// cwd doesn't cancel-and-restart the request.
    @ObservationIgnored var nameSuggestionTasks: [UUID: (path: String, task: Task<Void, Never>)] = [:]
    /// In-memory memo of path -> suggestion (or nil for NONE/junk/error) so
    /// repeated cds into the same folder don't re-prompt the model. Distinct
    /// from `SessionNameCache` and deliberately never persisted — AI names
    /// are ephemeral and must re-resolve on every launch.
    @ObservationIgnored private var nameSuggestionMemo: [String: String?] = [:]
    private static let nameSuggestionMemoCap = 256
    /// One in-flight AI naming request per Tab, keyed by tab id (#0260).
    /// Shares `nameSuggestionMemo` with session naming — both are keyed
    /// purely by cwd, so a directory named for one session's anchor tab
    /// answers every other tab's request for that same directory without
    /// a second on-device model call.
    @ObservationIgnored var tabNameSuggestionTasks: [UUID: (path: String, task: Task<Void, Never>)] = [:]

    // MARK: - Per-window state

    /// All content windows. One element in the current (phase 2) single-window
    /// era; grows in `#0237` when `New Window` is added.
    @ObservationIgnored public private(set) var windows: [WindowRuntime]

    /// The id `init` seeded `windows[0]` with, captured independently of
    /// `windows` itself (#0316). `initialWindowID` falls back to this when
    /// `windows` is legitimately empty — the deliberate post-last-window-close
    /// state `terminateIfLastContentWindowGone()`'s doc comment describes —
    /// so a `WindowGroup` scene-body re-evaluation during that window can
    /// never index an empty array. A scene body must stay pure (no writes,
    /// no `Task` hops — `docs/swiftui-observation-rules.md`), so the fix has
    /// to be "always have a valid value on hand," not "compute one on demand."
    @ObservationIgnored private let seedWindowID: WindowID

    /// The `WindowID` that `BattyApp`'s `WindowGroup` must use as its
    /// `defaultValue`. Exposing it here lets SwiftUI reuse `windows[0]`
    /// (seeded in `init`) for the first on-screen window rather than creating
    /// a phantom second runtime — the root cause of the #0251 wrong-window bug
    /// where `batty <path>` sessions landed in a runtime SwiftUI never showed.
    ///
    /// Falls back to `seedWindowID` when `windows` is empty (#0316) rather
    /// than indexing `windows[0]` unconditionally. That state is reachable
    /// from a scene body while the app deliberately lives with `windows == []`
    /// for one extra run-loop turn after the last content window closes (see
    /// `terminateIfLastContentWindowGone`). Reusing the original seed id — not
    /// a fresh `WindowID()` — keeps behavior identical to today whenever a
    /// window exists, and if this is ever read in the empty-window turn,
    /// resolves to the same id `windowRuntime(for:)` would recreate a runtime
    /// for on demand, matching that method's existing lazy-creation contract
    /// rather than inventing a new one.
    ///
    /// Load-bearing invariant, named here because a multi-window change
    /// (#0234) could break it silently: reading this in the empty-window turn
    /// *does* revive a runtime, because `windowRuntime(for:)` lazily creates
    /// one and appends it to `windows`. That is safe only because it is
    /// created with `sessions: []` and because `terminateIfLastContentWindowGone`
    /// re-checks `windows.allSatisfy { $0.sessions.isEmpty }` rather than
    /// `windows.isEmpty` — so a revived empty runtime does not cancel
    /// termination. Revive with a session attached and the app would instead
    /// stay alive headless.
    public var initialWindowID: WindowID {
        windows.first?.id ?? seedWindowID
    }

    /// Returns the `WindowRuntime` for `windowID`, creating one lazily if
    /// it does not yet exist. This is the single path for launch, New Window,
    /// and restoration — all converge here so a new scene and a new runtime
    /// are always created together. The initial window seeded in `init` uses
    /// a known `WindowID`; subsequent windows create a fresh runtime with a
    /// fresh `Session 1` in `$HOME` (no cross-window CWD inheritance).
    public func windowRuntime(for windowID: WindowID) -> WindowRuntime {
        if let existing = windows.first(where: { $0.id == windowID }) {
            return existing
        }
        logger.info("windowRuntime: creating new runtime for windowID=\(windowID.value, privacy: .public)")
        let runtime = WindowRuntime(
            id: windowID,
            sessions: [],
            bellFeed: bellFeed,
            nameCache: nameCache
        )
        // Wire onAllSessionsClosed: closing the last session in a window
        // closes the window itself. RootWindowView maps this to an NSWindow
        // close via the window-close callback set in its view tree. The
        // app terminates separately when the last content window closes
        // (observed in unregisterNSWindow / windowWillClose path).
        // This closure is replaced by `RootWindowView` when the window's
        // view tree is live.
        runtime.onAllSessionsClosed = { [weak runtime] in
            guard let runtime else { return }
            logger.info("onAllSessionsClosed windowID=\(runtime.id.value, privacy: .public): no sessions remaining; requesting window close")
            runtime.closeWindowCallback?()
        }
        windows.append(runtime)
        return runtime
    }

    /// Removes the `WindowRuntime` with the given `id` from `windows`.
    /// Called from the window-close teardown path after all tabs in the
    /// window have been released. Safe to call with an unknown id.
    public func removeWindow(id windowID: WindowID) {
        windows.removeAll { $0.id == windowID }
        logger.info("removeWindow windowID=\(windowID.value, privacy: .public); remaining windows=\(self.windows.count, privacy: .public)")
        // If no registered content windows remain and there was more than
        // one, the app can terminate. With a single-window history the
        // normal path is the onAllSessionsClosed → window close → this
        // remove → terminateIfLastContentWindowGone sequence.
        terminateIfLastContentWindowGone()
    }

    /// Terminates the app when no content windows remain in the registry.
    /// A content window is one registered via `registerNSWindow(_:for:)`.
    /// Help and Settings are not registered and therefore not counted.
    ///
    /// **Why the actuation is deferred (#0311).** `unregisterNSWindow`/
    /// `removeWindow` call this synchronously from `WindowDelegate
    /// .windowWillClose(_:)` — a genuine `NSWindowDelegate` callback running
    /// deep inside AppKit's own window-closing call stack (`_finishClosingWindow`
    /// → `postNotificationName:` → this delegate). Calling `NSApp.terminate(nil)`
    /// directly from there matches the field crash report's stack, and was
    /// directly reproduced: a Debug-configuration Beta build with this exact
    /// synchronous path (no deferral) crashed 2/2 trials closing its last
    /// window ~1.5-2s after launch, with a fully symbolicated stack trapping
    /// at `BattyCommands.keyWindow`'s `Array` subscript — see
    /// `issues/0311/BattyBeta-2026-08-07-011614-prefix-repro.ips` and
    /// `issues/0311.md`'s Notes for the method and full stack. The original
    /// *field* crash (1.1.0, Release configuration, no dSYM) is not itself
    /// symbolicated, so that specific binary's trap is a mechanism match
    /// rather than a byte-for-byte confirmed replay — but the mechanism
    /// itself, including which line traps, is no longer inferred.
    ///
    /// **This deferral is re-entrancy hygiene, not the crash fix.** `windows`
    /// is `@ObservationIgnored` (see its declaration above), so emptying it
    /// does not itself invalidate the `Commands` body — the re-evaluation
    /// that trapped was driven by some *other* pending SwiftUI transaction
    /// that AppKit's terminate-time run-loop spin happened to flush, not by
    /// this method's own writes. `BattyCommands.keyWindow`'s prior `store
    /// .windows[0]` (now `store.keyWindowOrFirstRegistered()`, fixed in the
    /// same #0311 diff) is what actually closed the crash: it is necessary
    /// and sufficient on its own — confirmed by the reproduction above,
    /// where the fixed build did not crash under the identical synchronous
    /// path. This deferral does not close the window in which `windows`
    /// can be observed empty from a re-evaluated `Commands` body — if
    /// anything it measurably *lengthens* that window, by keeping the app
    /// alive with an empty `windows` for an extra run-loop turn instead of
    /// terminating near-immediately. It is still worth doing on its own
    /// re-entrancy-hygiene merits (not calling `NSApp.terminate` from inside
    /// AppKit's own window-closing call stack), but every other trap-capable
    /// read of `windows` that can run during that widened gap remains
    /// reachable — see Gotchas in `issues/0311.md` for the known sites, left
    /// unfixed here and tracked as a follow-up.
    ///
    /// The fix defers only the *actuation* — `terminateHandler()` — to the next
    /// run-loop turn via `DispatchQueue.main.async`, so it executes outside any
    /// nested AppKit call stack rather than inside one. The state mutations
    /// that produced this decision (`windows.removeAll`, `nsWindowMap
    /// .removeValue`) are unchanged: they still happen synchronously, in the
    /// same place, before this method is even called. Nothing about the
    /// store's observable state is deferred — only the imperative call to quit.
    ///
    /// This is deliberately not the `Task`-hop CLAUDE.md and the #0229
    /// regression warn against. That bug deferred a *write* that a second
    /// writer was racing over the same fact (model → AppKit focus vs. AppKit
    /// → model echo). `windows`/`nsWindowMap` do have other writers besides
    /// this method's own call sites — notably `windowRuntime(for:)`, which
    /// can append a new window (e.g. a New Window action) in the gap before
    /// the deferred block runs, exactly what
    /// `deferredTerminateAbortsIfANewWindowAppearsBeforeItRuns` exercises —
    /// so soundness here does **not** come from writer exclusivity. It comes
    /// from the deferred block re-reading live `self.windows`/
    /// `self.nsWindowMap` at execution time rather than trusting a captured
    /// decision: if the world moved on before the next turn, the stale
    /// decision aborts instead of terminating on outdated state. That is the
    /// same staleness-guard shape `docs/swiftui-observation-rules.md`
    /// prescribes for model-initiated AppKit follow-ups ("carries a
    /// staleness guard ... so a superseded follow-up can never fire late").
    /// A future writer of `windows`/`nsWindowMap` (#0234 will add some) must
    /// preserve this: the deferred block reads live store state, never a
    /// snapshot taken at decision time.
    private func terminateIfLastContentWindowGone() {
        // The nsWindowMap only contains live registered windows. When it's
        // empty, all content windows have closed.
        guard nsWindowMap.isEmpty else { return }
        // Guard: if there are still WindowRuntime entries that haven't been
        // removed yet (e.g. due to concurrent teardown), also check windows.
        // A window with sessions still attached is not truly gone.
        guard windows.allSatisfy({ $0.sessions.isEmpty }) else { return }
        guard !terminationScheduled else { return }
        terminationScheduled = true
        logger.info("terminateIfLastContentWindowGone: no content windows remain; scheduling termination")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.terminationScheduled = false
            guard self.nsWindowMap.isEmpty, self.windows.allSatisfy({ $0.sessions.isEmpty }) else {
                logger.info("terminateIfLastContentWindowGone: state changed before the deferred check ran; aborting")
                return
            }
            logger.info("terminateIfLastContentWindowGone: terminating (deferred)")
            self.nameCache.save()
            self.terminateHandler()
        }
    }

    // MARK: - NSWindow ↔ WindowID registry

    /// The number of registered content windows. Used by `BattyAppDelegate` to
    /// log the window count when handling external URL events — helps diagnose
    /// whether SwiftUI created a spurious second window (#0251 second root cause).
    public var registeredContentWindowCount: Int { nsWindowMap.count }

    // MARK: - XPC status (#0271)

    /// Snapshots current app state for the `status` XPC verb. Tab counting
    /// mirrors `BattyAppDelegate.applicationShouldTerminate`'s `totalTabs`
    /// computation — both walk every window's sessions' `tree.allPanes`.
    public func statusPayload() -> StatusPayload {
        let totalSessions = windows.reduce(0) { $0 + $1.sessions.count }
        // Only `.terminal`-kind panes contribute — a non-terminal pane's one
        // `TabRuntime` is a structural placeholder with no live Terminal
        // Session behind it (`PaneRuntime.kind`'s doc comment), and
        // `batty status`'s `tabCount` should report real tabs (#0315 review
        // round 1, finding 3).
        let totalTabs = windows.reduce(0) { acc, window in
            acc + window.sessions
                .flatMap { $0.tree.allPanes }
                .filter { $0.kind == .terminal }
                .flatMap { $0.tabs }
                .count
        }
        return StatusPayload(
            pid: ProcessInfo.processInfo.processIdentifier,
            uptimeSeconds: Date().timeIntervalSince(launchDate),
            windowCount: windows.count,
            sessionCount: totalSessions,
            tabCount: totalTabs
        )
    }

    // MARK: - XPC topology (#0274)

    /// Full topology for the `list` XPC verb: every window, its sessions,
    /// and each session's pane/tab tree. Purely a read over `windows` —
    /// see `TopologyPayloadBuilder.swift` for the walk. Never touches
    /// `selectedSessionID`, `focusedPaneID`, or `activeTabID`, so listing a
    /// background session's topology cannot steal focus or switch the
    /// active session.
    public func topologyPayload() -> TopologyPayload {
        TopologyPayload(
            pid: ProcessInfo.processInfo.processIdentifier,
            windows: windows.map { $0.topologyPayload() }
        )
    }

    /// The slice for a single session, for the `sessionInfo` XPC verb.
    ///
    /// `sessionID` resolves an explicit target across *all* windows (not
    /// just the key window) so a caller in a background session can ask
    /// about itself. `sessionID == nil` falls back to the focused session
    /// — today that means the key window's selected session, or the first
    /// window's selected/first session when no window is key (headless CLI
    /// callers, unit tests). This is the seam #0257's `BATTY_SESSION_ID`
    /// env-var fallback slots into later: the eventual order is `--session`
    /// flag → `BATTY_SESSION_ID` → focused session, of which only the first
    /// and last exist today — the middle branch is #0257's to add, and it
    /// inserts here without changing this method's signature or the reply
    /// schema.
    ///
    /// Returns `nil` when an explicit `sessionID` doesn't resolve to any
    /// session in any window, or when there is no session to fall back to
    /// (no windows, or a window with an empty session list — both
    /// unreachable in practice since every window seeds one session, but
    /// handled rather than force-unwrapped).
    public func sessionInfoPayload(sessionID: UUID? = nil) -> TopologySessionPayload? {
        if let sessionID {
            for window in windows {
                if let session = window.sessions.first(where: { $0.id == sessionID }) {
                    return session.topologyPayload(isActive: window.selectedSessionID == session.id)
                }
            }
            return nil
        }
        guard let window = keyWindowRuntime() ?? windows.first,
              let session = window.selectedSession ?? window.sessions.first
        else {
            return nil
        }
        return session.topologyPayload(isActive: window.selectedSessionID == session.id)
    }

    // MARK: - XPC pane split (#0282)

    /// The pane to target when an XPC mutation verb (`pane split` #0282,
    /// later `pane close` #0283) receives no explicit pane id — the same
    /// "focused element" fallback `sessionInfoPayload(sessionID: nil)` uses
    /// one level up, resolved to the target *session*'s `focusedPaneID`
    /// rather than the session itself. `nil` only when there is no
    /// window/session to fall back to (unreachable in practice — every
    /// window seeds one session — but handled rather than force-unwrapped).
    public func focusedPaneIDFallback() -> UUID? {
        guard let window = keyWindowRuntime() ?? windows.first,
              let session = window.selectedSession ?? window.sessions.first
        else { return nil }
        return session.tree.focusedPaneID
    }

    /// The tab to target when the XPC `notify` verb (#0284) receives no
    /// explicit `--tab` id and no `BATTY_TAB_ID` env — one tier below
    /// `focusedPaneIDFallback()`, since a `BellFeedEntry` needs a real tab,
    /// not merely a real pane: the focused pane's active tab. `nil` only
    /// when there is no window/session/pane to fall back to (unreachable in
    /// practice, mirroring `focusedPaneIDFallback()`'s own note).
    public func focusedTabIDFallback() -> UUID? {
        guard let paneID = focusedPaneIDFallback(),
              let window = keyWindowRuntime() ?? windows.first
        else { return nil }
        for session in window.sessions {
            if let pane = session.tree.allPanes.first(where: { $0.id == paneID }) {
                return pane.activeTabID
            }
        }
        return nil
    }

    /// Splits `paneID`'s owning session, adjacent to that pane — #0282's
    /// XPC `pane split` verb. Searches every window's every session (not
    /// just the key window) so a background-session target resolves
    /// identically to a foreground one, per #0257's "placement is relative
    /// to the target pane's own split tree" rule.
    ///
    /// Returns the new pane's id, or `nil` when `paneID` is not found in any
    /// window/session — the stale/unknown-id case `AppXPCService` turns into
    /// a failure reply (CLI exit `4`); the entire reason this verb moved to
    /// XPC instead of staying on the fire-and-forget `batty://` scheme.
    ///
    /// Never touches `selectedSessionID` — mutating a background target must
    /// not steal focus or switch the active session (#0257). See
    /// `SplitTree.splitPane(id:direction:ratio:command:)` for the
    /// tree-focus decision (moves only when `paneID` was already that
    /// tree's focused pane).
    @discardableResult
    public func splitPane(id paneID: UUID, direction: SplitDirection, command: String? = nil, kind: PaneContentKind = .terminal) -> UUID? {
        for window in windows {
            for session in window.sessions where session.tree.root.contains(paneID: paneID) {
                return session.tree.splitPane(id: paneID, direction: direction, command: command, kind: kind)?.id
            }
        }
        return nil
    }

    // MARK: - XPC pane close (#0283)

    /// Ends every Tab's Terminal Session in `paneID` and removes its region
    /// from its owning session's split tree — #0283's XPC `pane close`
    /// verb. Searches every window's every session, same as `splitPane`, so
    /// a background-session target resolves identically to a foreground
    /// one; the actual mutation happens in `WindowRuntime.closePane`, which
    /// never touches `selectedSessionID` unless the closed pane emptied its
    /// own session (in which case `removeSession`'s existing, already-safe
    /// "only reassign if the removed session was selected" behavior
    /// applies).
    ///
    /// Refuses (`.refusedLastPane`) rather than closing the app's very last
    /// pane across every window: see `PaneCloseOutcome.refusedLastPane` — an
    /// unattended XPC caller must not have a one-command path into #0217's
    /// silent-quit cascade. Nothing in the UI calls this method today (no
    /// pane-level close exists outside this verb), so the guard only ever
    /// applies to XPC-driven closes.
    ///
    /// The refusal condition counts panes directly (`totalPanes == 1`)
    /// rather than proxying through `windows.count == 1` — a `WindowRuntime`
    /// can linger in `windows` with an empty `sessions` array (its own doc
    /// comment on `closeWindowCallback` notes a session can close before the
    /// view tree wires up the real NSWindow), which would make the
    /// window-count proxy read `false` while the app genuinely has one pane
    /// left. Counting panes is immune to that: an empty `WindowRuntime`
    /// contributes zero to the sum either way.
    @discardableResult
    public func closePane(id paneID: UUID) -> PaneCloseOutcome {
        let totalPanes = windows.reduce(0) { $0 + $1.sessions.reduce(0) { $0 + $1.tree.allPanes.count } }
        for window in windows where window.sessions.contains(where: { $0.tree.root.contains(paneID: paneID) }) {
            return window.closePane(id: paneID, refuseIfAppsLastPane: totalPanes == 1)
        }
        return .unknownPane
    }

    /// Registers the association between an `NSWindow` and its `WindowID`.
    /// Called from `WindowIDRegistrar` in each window's SwiftUI tree once
    /// the hosting NSWindow is known (from `updateNSView`, deferred off the
    /// update pass). Safe to call multiple times — idempotent per window.
    public func registerNSWindow(_ nsWindow: NSWindow, for windowID: WindowID) {
        let wasNew = nsWindowMap[ObjectIdentifier(nsWindow)] == nil
        nsWindowMap[ObjectIdentifier(nsWindow)] = windowID
        if wasNew {
            logger.debug("registerNSWindow: windowID=\(windowID.value, privacy: .public) registeredContentWindows=\(self.nsWindowMap.count, privacy: .public)")
        }
    }

    /// Removes a closed window from the registry. Called from the window's
    /// NSWindowDelegate `windowWillClose` path after teardown (releasing
    /// tabs, host). Triggers app termination when the last content window
    /// has been closed.
    public func unregisterNSWindow(_ nsWindow: NSWindow) {
        nsWindowMap.removeValue(forKey: ObjectIdentifier(nsWindow))
        logger.info("unregisterNSWindow: registered content windows remaining=\(self.nsWindowMap.count, privacy: .public)")
        terminateIfLastContentWindowGone()
    }

    /// True when `NSApp.keyWindow` is a registered content window (as opposed
    /// to Settings, Help, or panels). Replaces the `mainWindowIsKey()` heuristic
    /// that breaks under `WindowGroup` (identifiers differ per window).
    public func keyWindowIsContentWindow() -> Bool {
        guard let key = NSApplication.shared.keyWindow else { return false }
        return nsWindowMap[ObjectIdentifier(key)] != nil
    }

    /// The `WindowRuntime` for the currently-key content window, if any.
    /// Returns `nil` in unit-test contexts where no window is key.
    /// Used by `BattyShortcuts` to target shortcut dispatch at the right window.
    public func keyWindowRuntime() -> WindowRuntime? {
        guard let key = NSApplication.shared.keyWindow,
              let windowID = nsWindowMap[ObjectIdentifier(key)] else { return nil }
        return windows.first { $0.id == windowID }
    }

    /// The `WindowRuntime` that `BattyCommands.keyWindow` targets: the key
    /// content window if any, otherwise the first entry in `windows` — not
    /// filtered through `nsWindowMap` the way `anyContentWindowRuntime()` is,
    /// so it also resolves in preview/unit-test contexts where no `NSWindow`
    /// is registered yet.
    ///
    /// Extracted out of `BattyCommands` (#0311 review round 1) so the
    /// fallback logic has a real unit test exercising the exact production
    /// expression, not a copy of it re-typed into a test — `Commands` bodies
    /// themselves can't be unit-tested directly (`docs/swiftui-observation
    /// -rules.md`'s Commands-body caution), so this is the closest testable
    /// seam to it. Returns `nil`, never traps, when `windows` is empty —
    /// see `terminateIfLastContentWindowGone`'s doc comment for why that can
    /// happen and for how long.
    public func keyWindowOrFirstRegistered() -> WindowRuntime? {
        keyWindowRuntime() ?? windows.first
    }

    /// The `WindowRuntime` for any registered content window. Used as a
    /// fallback when `keyWindowRuntime()` is nil but the app-level URL handler
    /// needs to target a visible window (e.g. `batty <path>` during the brief
    /// interval between window creation and NSWindow registration). Returns the
    /// key-window runtime when available; falls back to the first registered
    /// window. Returns nil when no window is registered (unit-test context or
    /// before the first content window appears in the view hierarchy).
    public func anyContentWindowRuntime() -> WindowRuntime? {
        if let key = keyWindowRuntime() { return key }
        // Find any registered content window and return its runtime.
        guard let windowID = nsWindowMap.values.first else { return nil }
        return windows.first { $0.id == windowID }
    }

    // MARK: - Init

    public init(
        sessions: [SessionRuntime] = [],
        bellFeed: BellFeedStore = BellFeedStore(),
        nameCache: SessionNameCache = SessionNameCache(),
        notifier: BellNotifying? = nil
    ) {
        self.bellFeed = bellFeed
        self.nameCache = nameCache
        self.notifier = notifier
        self.themeChrome = ThemeChrome(palette: ChromePalette(theme: ThemePreference.activeTheme()))
        let window = WindowRuntime(
            sessions: sessions,
            bellFeed: bellFeed,
            nameCache: nameCache
        )
        // Wire the initial window the same way windowRuntime(for:) wires
        // newly created windows: onAllSessionsClosed → closeWindowCallback.
        // RootWindowView sets closeWindowCallback once the NSWindow is live.
        window.onAllSessionsClosed = { [weak window] in
            guard let window else { return }
            logger.info("onAllSessionsClosed windowID=\(window.id.value, privacy: .public): no sessions remaining; requesting window close")
            window.closeWindowCallback?()
        }
        self.windows = [window]
        self.seedWindowID = window.id
        footprintMonitor.onWarn = { [weak self] footprintBytes, step in
            self?.recordFootprintWarning(footprintBytes: footprintBytes, step: step)
        }
    }

    // MARK: - Per-window forwarding shims
    //
    // Read-property shims resolve to windows[0]. They are only used from
    // unit-test and UITestDriver contexts where a single window is present;
    // view code uses the per-window `WindowRuntime` from the environment
    // directly. Redefining them to call `keyWindowRuntime()` would break
    // the observation contract — `keyWindowRuntime()` reads
    // `NSApplication.shared.keyWindow`, which is not @Observable, so views
    // reading these computed properties would not re-invalidate when the key
    // window changes (#0248 view-read-path caution).
    //
    // Action shims (below) resolve to the key window so that operations
    // dispatched from NSEvent monitors and other app-global paths target the
    // window the user is interacting with, not always windows[0].

    public var sessions: [SessionRuntime] {
        // windows[0]: read-only shim used only in unit tests and UITestDriver.
        windows[0].sessions
    }

    public var selectedSessionID: UUID? {
        // windows[0]: read-only shim used only in unit tests and UITestDriver.
        get { windows[0].selectedSessionID }
        set { windows[0].selectedSessionID = newValue }
    }

    public var selectedSession: SessionRuntime? {
        // windows[0]: read-only shim used only in unit tests and UITestDriver.
        windows[0].selectedSession
    }

    public var pendingCloseRequest: PendingCloseRequest? {
        // windows[0]: read-only shim used only in unit tests and UITestDriver.
        get { windows[0].pendingCloseRequest }
        set { windows[0].pendingCloseRequest = newValue }
    }

    /// Returns `nil` (#0316) only in the deliberate post-last-window-close
    /// state — `windows` empty and no registered content window —
    /// `terminateIfLastContentWindowGone()`'s doc comment describes: the
    /// process is already committed to quitting, so there is no window left
    /// to receive a new session, and creating one would fight the pending
    /// termination rather than serve a request the user can even see acted
    /// on. Both current callers (`BattyURLHandler`, a `batty://` URL delivered
    /// in exactly that race, and `UITestDriver`) already discard the return
    /// value or handle a missing match, so dropping the request with a log
    /// line — rather than reviving a phantom window to hold it — does not
    /// change observable behavior outside that one-runloop-turn race.
    @discardableResult
    public func addSession(title: String? = nil, workingDirectory: String? = nil) -> SessionRuntime? {
        // anyContentWindowRuntime() tries keyWindowRuntime() first (the normal
        // in-app path), then any registered content window (the URL-handler
        // path when the key window hasn't been registered yet, e.g. batty <path>
        // delivered before WindowIDRegistrar fires — #0251). Falls back to
        // windows.first only in unit-test contexts where no NSWindow is
        // registered and windows[0] is the canonical single runtime.
        guard let target = anyContentWindowRuntime() ?? windows.first else {
            logger.error("addSession: no window available (windows empty); dropping request workingDirectory=\(workingDirectory ?? "<nil>", privacy: .public)")
            return nil
        }
        logger.debug("addSession: targeting windowID=\(target.id.value, privacy: .public) totalWindows=\(self.windows.count, privacy: .public) registeredContentWindows=\(self.nsWindowMap.count, privacy: .public) workingDirectory=\(workingDirectory ?? "<nil>", privacy: .public)")
        return target.addSession(title: title, workingDirectory: workingDirectory)
    }

    public func removeSession(id: UUID) {
        cancelNameSuggestion(forSessionID: id)
        // Locate the owning window by session ID — the session may be in any window.
        windowOwning(sessionID: id)?.removeSession(id: id)
    }

    public func renameSession(id: UUID, to newTitle: String) {
        // Locate the owning window by session ID — the session may be in any window.
        windowOwning(sessionID: id)?.renameSession(id: id, to: newTitle)
        // Cancel any in-flight AI naming — an explicit user rename pins
        // the title and must not be overwritten by a late suggestion.
        cancelNameSuggestion(forSessionID: id)
    }

    public func clearSessionName(id: UUID) {
        // Locate the owning window by session ID — the session may be in any window.
        windowOwning(sessionID: id)?.clearSessionName(id: id)
    }

    @discardableResult
    public func duplicateSession(id: UUID) -> SessionRuntime? {
        windowOwning(sessionID: id)?.duplicateSession(id: id)
    }

    /// No production caller today (#0316: views and `BattyCommands`/
    /// `BattyShortcuts` call the per-window `WindowRuntime` method directly);
    /// kept total anyway so a future caller of this public shim can't
    /// reintroduce the #0311 trap class. No-ops (with a log line) when
    /// `windows` is empty rather than acting on a phantom window.
    public func moveSessions(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let window = keyWindowOrFirstRegistered() else {
            logger.notice("moveSessions: no window available (windows empty); ignoring")
            return
        }
        window.moveSessions(fromOffsets: source, toOffset: destination)
    }

    /// No production caller today (#0316: see `moveSessions`'s note above;
    /// same reasoning applies here).
    public func selectSession(at index: Int) {
        guard let window = keyWindowOrFirstRegistered() else {
            logger.notice("selectSession: no window available (windows empty); ignoring")
            return
        }
        window.selectSession(at: index)
    }

    public func closeTab(id tabID: UUID) {
        cancelTabNameSuggestion(forTabID: tabID)
        // Locate the owning window to route the close to the correct
        // WindowRuntime rather than defaulting to windows[0].
        for window in windows {
            if window.locate(tabID: tabID) != nil {
                window.closeTab(id: tabID)
                return
            }
        }
    }

    /// Called by `UITestDriver` (#0316: env-var-gated, compiled into the
    /// product but not a production caller today). Kept total anyway — see
    /// `moveSessions`'s note above.
    public func closeFocusedTab() {
        guard let window = keyWindowOrFirstRegistered() else {
            logger.notice("closeFocusedTab: no window available (windows empty); ignoring")
            return
        }
        window.closeFocusedTab()
    }

    public func requestCloseTab(id tabID: UUID) {
        // Locate the owning window so the close-confirmation sheet appears
        // on the correct window's session, not always windows[0].
        for window in windows {
            if window.locate(tabID: tabID) != nil {
                window.requestCloseTab(id: tabID)
                return
            }
        }
    }

    /// No production caller today (#0316: see `moveSessions`'s note above).
    public func requestCloseFocusedTab() {
        guard let window = keyWindowOrFirstRegistered() else {
            logger.notice("requestCloseFocusedTab: no window available (windows empty); ignoring")
            return
        }
        window.requestCloseFocusedTab()
    }

    public func requestCloseOtherTabs(paneID: UUID, keepingTabID: UUID) {
        // Locate the owning window via pane ID so the operation targets
        // the correct window, not always windows[0].
        for window in windows {
            if window.sessions.contains(where: { $0.tree.allPanes.contains(where: { $0.id == paneID }) }) {
                window.requestCloseOtherTabs(paneID: paneID, keepingTabID: keepingTabID)
                return
            }
        }
    }

    /// No production caller today (#0316: see `moveSessions`'s note above).
    public func confirmPendingClose() {
        guard let window = keyWindowOrFirstRegistered() else {
            logger.notice("confirmPendingClose: no window available (windows empty); ignoring")
            return
        }
        window.confirmPendingClose()
    }

    /// No production caller today (#0316: see `moveSessions`'s note above).
    public func cancelPendingClose() {
        guard let window = keyWindowOrFirstRegistered() else {
            logger.notice("cancelPendingClose: no window available (windows empty); ignoring")
            return
        }
        window.cancelPendingClose()
    }

    public func focusPane(id: UUID) {
        // Locate the pane's owning window so focus is applied to the
        // correct WindowRuntime rather than always windows[0].
        for window in windows {
            if window.sessions.contains(where: { $0.tree.allPanes.contains(where: { $0.id == id }) }) {
                window.focusPane(id: id)
                return
            }
        }
    }

    /// Hides the pane with `id`, routing to the owning window. No-op when the
    /// pane is the last visible pane in its session (≥1 visible invariant).
    public func hidePane(id: UUID) {
        for window in windows {
            if window.sessions.contains(where: { $0.tree.allPanes.contains(where: { $0.id == id }) }) {
                window.hidePane(id: id)
                return
            }
        }
    }

    /// Un-hides the pane with `id`, routing to the owning window.
    public func showPane(id: UUID) {
        for window in windows {
            if window.sessions.contains(where: { $0.tree.allPanes.contains(where: { $0.id == id }) }) {
                window.showPane(id: id)
                return
            }
        }
    }

    public func focusPane(containingTabID tabID: UUID) {
        // Locate the owning window via tab ID. This is also called from
        // TerminalClickFocusMonitor (event origin), so using the owning
        // window is more precise than keyWindowRuntime() — the clicked
        // terminal's window IS the target, and it may not yet be key
        // (the AppKit makeFirstResponder call comes in the same event).
        for window in windows {
            if window.locate(tabID: tabID) != nil {
                window.focusPane(containingTabID: tabID)
                return
            }
        }
    }

    public func jumpToTab(sessionID: UUID, tabID: UUID) {
        // Locate the owning window by session ID so the jump navigates the
        // correct window's state, not always windows[0].
        windowOwning(sessionID: sessionID)?.jumpToTab(sessionID: sessionID, tabID: tabID)
    }

    /// Marks the active tab in the key content window as seen. Falls back to
    /// `windows.first` when no key window is identified (unit-test context,
    /// or before the first window registers), and no-ops when `windows` is
    /// empty (#0316) — reachable from `PaneView`'s
    /// `onChange(of: pane.activeTabID)` (`markActiveTabSeen` is also this
    /// method's production caller) during the deliberate post-last-window-
    /// close turn `terminateIfLastContentWindowGone()` describes. There is no
    /// tab left to mark seen at that point, so silently no-oping is the
    /// correct behavior, not a degraded one. In multi-window production, this
    /// clears bells for whichever tab just became active in the key window —
    /// a tab in a non-key window gaining a new active tab doesn't clear its
    /// bells.
    public func markActiveTabSeen() {
        keyWindowOrFirstRegistered()?.markActiveTabSeen()
    }

    // MARK: - Bell event routing (global — searches across all windows)

    /// Records a BEL tick from the tab with `tabID`. The `windowID` field
    /// on the resulting `BellFeedEntry` is set to the owning window's ID
    /// (retired: the throwaway `UUID()` default from before #0239).
    /// A bell counts as "seen at creation" only when the tab is the active
    /// focused tab AND, when multiple content windows are registered, the
    /// owning window is the key window. In single-window mode (no registered
    /// key window, as in unit tests), `isFocused` alone determines seen-ness.
    public func recordBellTick(forTabID tabID: UUID, surfaceID: UUID = UUID()) {
        let keyWindowID = keyWindowRuntime()?.id
        let multiWindow = keyWindowID != nil
        for window in windows {
            guard let location = window.locate(tabID: tabID) else { continue }
            let delta = location.tab.recordBellTickIfNeeded()
            guard delta > 0 else { return }
            // In multi-window mode: seen requires both in-window focus AND key-window.
            // In single-window / no-key-window mode: isFocused alone (preserves
            // existing single-window test semantics).
            let isOwnerKey = !multiWindow || window.id == keyWindowID
            let effectivelySeen = location.isFocused && isOwnerKey
            for _ in 0..<delta {
                let entry = BellFeedEntry(
                    timestamp: location.tab.lastBellAt ?? Date(),
                    windowID: window.id.value,
                    sessionID: location.session.id,
                    paneID: location.pane.id,
                    tabID: location.tab.id,
                    surfaceID: surfaceID,
                    message: nil,
                    seen: effectivelySeen
                )
                // #0298: a seen-at-creation bell (tab currently focused)
                // always becomes its own entry — collapse only applies to
                // still-unread repeats, so `recordOrCollapse` is skipped
                // entirely rather than relying on it to find no candidate.
                let outcome: BellFeedStore.RecordOutcome = effectivelySeen
                    ? .recorded(bellFeed.record(entry))
                    : bellFeed.recordOrCollapse(entry)
                if !effectivelySeen {
                    window.propagateUnseenForced(at: location)
                }
                switch outcome {
                case .recorded:
                    postNotification(for: entry, at: location, trigger: .bel)
                    scheduleSummarization(for: entry, tabTitle: location.tab.terminal.title, sessionTitle: location.session.title)
                case .collapsed:
                    recordCollapsedNotificationDecision(for: entry, at: location, trigger: .bel)
                }
            }
            return
        }
    }

    /// Records a desktop notification event (OSC 9 / OSC 777) from the tab
    /// with `tabID`. `windowID` on the entry carries the real owning window's
    /// ID; in multi-window mode a bell is only "seen at creation" if the owning
    /// window is the key content window and the tab is the focused active tab.
    public func recordDesktopNotification(forTabID tabID: UUID, surfaceID: UUID = UUID()) {
        let keyWindowID = keyWindowRuntime()?.id
        let multiWindow = keyWindowID != nil
        for window in windows {
            guard let location = window.locate(tabID: tabID) else { continue }
            guard location.tab.recordDesktopNotificationIfNeeded() else { return }
            let isOwnerKey = !multiWindow || window.id == keyWindowID
            let effectivelySeen = location.isFocused && isOwnerKey
            let entry = BellFeedEntry(
                timestamp: location.tab.lastBellAt ?? Date(),
                windowID: window.id.value,
                sessionID: location.session.id,
                paneID: location.pane.id,
                tabID: location.tab.id,
                surfaceID: surfaceID,
                message: location.tab.lastBellMessage,
                seen: effectivelySeen
            )
            let outcome: BellFeedStore.RecordOutcome = effectivelySeen
                ? .recorded(bellFeed.record(entry))
                : bellFeed.recordOrCollapse(entry)
            if !effectivelySeen {
                window.propagateUnseenForced(at: location)
            }
            switch outcome {
            case .recorded:
                postNotification(for: entry, at: location, trigger: .oscNotification)
                scheduleSummarization(for: entry, tabTitle: location.tab.terminal.title, sessionTitle: location.session.title)
            case .collapsed:
                recordCollapsedNotificationDecision(for: entry, at: location, trigger: .oscNotification)
            }
            return
        }
    }

    /// Outcome of `recordCLINotification` — #0284's XPC `notify` verb.
    public enum NotifyOutcome: Equatable, Sendable {
        case posted
        /// No tab with that id exists in any window — the stale/unknown-id
        /// case `AppXPCService` turns into a failure reply (CLI exit `4`).
        case unknownTab
    }

    /// Posts a CLI-originated notification into the Bell Feed, attributed
    /// to a real tab — #0284's `notify` verb, the terminal step of the
    /// agent loop (#0257). Deliberately rides the same `BellFeedEntry`
    /// shape every other entry uses rather than growing a kind/placeholder-
    /// id path: `BellFeedView.pathLabel(for:)`'s `(closed)` fallback and
    /// `jumpToBellEntry`'s dead-window no-op both assume a live tab, so
    /// resolving to one for real makes click-to-jump, cleanup-on-close
    /// (`cleanUpBellState(forTabIDs:)`), and the AI summarizer all work
    /// unmodified instead of needing new UI-facing plumbing for a
    /// placeholder shape.
    ///
    /// Shares its post-resolution plumbing (`BellFeedEntry` construction,
    /// unseen propagation, `postNotification`, `scheduleSummarization`)
    /// with `recordBellTick`/`recordDesktopNotification` — it diverges only
    /// in how the tab id and message are obtained. There is no `TabRuntime`
    /// change-detection to run through here (unlike
    /// `recordBellTickIfNeeded`/`recordDesktopNotificationIfNeeded`, which
    /// dedupe against libghostty's own delta): a CLI `notify` invocation is
    /// deliberately exactly one entry per call, not a coalesced delta.
    ///
    /// `surfaceID` is set to the resolved tab id, not a fresh random UUID
    /// like the other two record methods' `surfaceID: UUID = UUID()`
    /// default — #0281's Gotchas flagged that default as vestigial (nothing
    /// reads it) and worth cleaning up "whenever the feed model is next
    /// touched." This is that touch, scoped to this new call site only; the
    /// existing two are left alone.
    @discardableResult
    public func recordCLINotification(tabID: UUID, title: String, body: String?, playSound: Bool) -> NotifyOutcome {
        let keyWindowID = keyWindowRuntime()?.id
        let multiWindow = keyWindowID != nil
        for window in windows {
            guard let location = window.locate(tabID: tabID) else { continue }
            let isOwnerKey = !multiWindow || window.id == keyWindowID
            let effectivelySeen = location.isFocused && isOwnerKey
            let entry = BellFeedEntry(
                timestamp: Date(),
                windowID: window.id.value,
                sessionID: location.session.id,
                paneID: location.pane.id,
                tabID: location.tab.id,
                surfaceID: location.tab.id,
                message: Self.formatNotifyMessage(title: title, body: body),
                seen: effectivelySeen
            )
            let outcome: BellFeedStore.RecordOutcome = effectivelySeen
                ? .recorded(bellFeed.record(entry))
                : bellFeed.recordOrCollapse(entry)
            if !effectivelySeen {
                window.propagateUnseenForced(at: location)
            }
            switch outcome {
            case .recorded:
                postNotification(for: entry, at: location, trigger: .cliNotification, playSound: playSound)
                scheduleSummarization(for: entry, tabTitle: location.tab.terminal.title, sessionTitle: location.session.title)
            case .collapsed:
                recordCollapsedNotificationDecision(for: entry, at: location, trigger: .cliNotification)
            }
            return .posted
        }
        return .unknownTab
    }

    private static func formatNotifyMessage(title: String, body: String?) -> String {
        guard let body, !body.isEmpty else { return title }
        return "\(title)\n\(body)"
    }

    // MARK: - Footprint warning (#0290)

    /// Fired by `footprintMonitor.onWarn` when a sample crosses a new
    /// soft-limit step. Records a Bell Feed entry stating the current
    /// footprint and Terminal Session count — so the user has something
    /// actionable to close — then asks `notifier` for the paired system
    /// notification (`BellNotifier.postFootprintWarning` only fires it when
    /// Batty isn't frontmost, since the Bell Feed's unseen dot already covers
    /// the frontmost case).
    ///
    /// `sessionCount` is read from `TerminalHostStore.shared` at call time
    /// so the number always reflects what's actually open when the warning
    /// fires, not a stale count captured when the sampling timer started.
    func recordFootprintWarning(footprintBytes: UInt64, step: Int) {
        let sessionCount = TerminalHostStore.shared.terminalSessionCount
        let footprintText = Self.formatGB(footprintBytes)
        let message = Self.footprintWarningMessage(footprintText: footprintText, sessionCount: sessionCount)
        logger.notice("recordFootprintWarning: step=\(step, privacy: .public) footprint=\(footprintBytes, privacy: .public) sessionCount=\(sessionCount, privacy: .public)")
        let entry = BellFeedEntry(
            timestamp: Date(),
            windowID: BellFeedEntry.systemID,
            sessionID: BellFeedEntry.systemID,
            paneID: BellFeedEntry.systemID,
            tabID: BellFeedEntry.systemID,
            surfaceID: BellFeedEntry.systemID,
            message: message,
            seen: false
        )
        bellFeed.record(entry)
        notifier?.postFootprintWarning(
            title: String(localized: "Batty — Memory Usage"),
            body: message,
            identifier: entry.id.uuidString
        )
    }

    /// The plural rule lives in `Localizable.xcstrings` (a manually-added
    /// "plural" variation, matching the other BattyKit strings extracted
    /// there by hand — see #0295), not an English ternary baked into the
    /// interpolation. All 15 locales currently carry the same English text
    /// (non-en marked `needs_review`), so every locale applies its own CLDR
    /// plural rule to the same words and gets correct singular/plural
    /// grammar today; translating the sentence itself into the other 14
    /// languages is separate future work, not blocked on this.
    ///
    /// `bundle`/`locale` default to the environment (`String(localized:)`'s
    /// own defaults) so production call sites don't need to pass anything;
    /// the parameters exist so a test can point `String(localized:)` at a
    /// bundle it compiled itself from the real catalog on disk. That's
    /// necessary, not just convenient: under `BattyKitTests`, `Bundle.main`
    /// resolves to the xctest runner, not `Batty.app`, so with no bundle
    /// override `String(localized:)` can't reach any compiled catalog and
    /// silently falls back to this function's own English source text —
    /// which would make a test look like it verified plural resolution
    /// while actually verifying nothing.
    static func footprintWarningMessage(
        footprintText: String,
        sessionCount: Int,
        bundle: Bundle = .main,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        String(
            localized: "Batty is using \(footprintText) across \(sessionCount) Terminal Sessions. Close some to free memory.",
            bundle: bundle,
            locale: locale
        )
    }

    /// `ByteCountFormatter` rounds to as few significant digits as it can
    /// (a footprint just over a 4 GB limit can render as "4 GB", making a
    /// warning look like it fired for no reason), and its `.memory` count
    /// style already uses 1024-based units under a decimal "GB" label — the
    /// same convention `SettingsPreference.resolvedFootprintSoftLimitBytes()`
    /// uses to turn the Settings GB stepper into bytes. Formatting by hand
    /// with a fixed two decimal places keeps the warning text visibly above
    /// whatever limit it just crossed.
    ///
    /// The divisor is `1_073_741_824` (2³⁰), i.e. GiB, not decimal GB — this
    /// is deliberate, not a bug to "correct" toward 1_000_000_000. Verified
    /// empirically (#0295): a process whose exact `phys_footprint` was known
    /// from `task_info` was independently reported by both `footprint -p`
    /// and `top` as bytes ÷ 2²⁰, and `ByteCountFormatter.CountStyle.memory`
    /// — Apple's own memory-display style — is likewise 1024-based under a
    /// decimal-looking "GB" label. Activity Monitor follows the same
    /// convention. So this divisor already matches both the number and the
    /// label Activity Monitor shows; switching to 1_000_000_000 would create
    /// the mismatch it might look like it's fixing.
    ///
    /// `locale` defaults to the environment so `formatted(_:)` renders the
    /// decimal separator the user's locale expects (comma, not always ".")
    /// — the app ships 15 locales via `Batty/Localizable.xcstrings`. The
    /// parameter exists so tests can pin a specific locale deterministically
    /// instead of depending on the test machine's locale.
    static func formatGB(_ bytes: UInt64, locale: Locale = .autoupdatingCurrent) -> String {
        let gb = Double(bytes) / 1_073_741_824
        let number = gb.formatted(.number.precision(.fractionLength(2)).locale(locale))
        return "\(number) GB"
    }

    public func markBellSeen(id: UUID) {
        guard let entry = bellFeed.markSeen(id: id) else { return }
        for window in windows {
            window.decrementUnseen(for: entry)
        }
    }

    public func markAllBellsSeen() {
        let touched = bellFeed.markAllSeen()
        for entry in touched {
            for window in windows {
                window.decrementUnseen(for: entry)
            }
        }
    }

    /// Jumps to the bell feed entry's owning window, makes it key and front
    /// (event-origin call — legal only from a user gesture such as a feed
    /// click or notification tap, never from view-update code), then navigates
    /// to the session/pane/tab. If the entry's window is no longer registered
    /// (the window was closed), the entry is marked seen and the jump no-ops.
    /// A system entry (`BellFeedEntry.systemID`, e.g. the footprint warning)
    /// takes the same no-op path — it never had an owning window to begin
    /// with, not a closed one.
    public func jumpToBellEntry(_ entry: BellFeedEntry) {
        // Resolve owning window by matching windowID in the entry.
        let owningWindowID = WindowID(entry.windowID)
        guard let owningWindow = windows.first(where: { $0.id == owningWindowID }) else {
            if entry.windowID == BellFeedEntry.systemID {
                logger.info("jumpToBellEntry: entry \(entry.id, privacy: .public) is a system entry with no owning window; marking seen")
            } else {
                logger.info("jumpToBellEntry: owning windowID=\(entry.windowID, privacy: .public) no longer live; marking entry seen")
            }
            markBellSeen(id: entry.id)
            return
        }
        // Bring the owning window forward. makeKeyAndOrderFront is a
        // responder-changing AppKit call: legal here because jumpToBellEntry
        // is only called from feed-click / notification-tap event handlers.
        if let nsWindow = nsWindow(for: owningWindowID) {
            logger.info("jumpToBellEntry: making window \(owningWindowID.value, privacy: .public) key and front")
            nsWindow.makeKeyAndOrderFront(nil)
        }
        owningWindow.jumpToBellEntry(entry)
    }

    /// Returns the `NSWindow` registered for `windowID`, if any.
    public func nsWindow(for windowID: WindowID) -> NSWindow? {
        for (key, id) in nsWindowMap where id == windowID {
            // Reverse-lookup: ObjectIdentifier → NSWindow requires iterating
            // all windows to find the one whose identifier matches. Since the
            // map is small (one entry per content window), this is fine.
            return NSApp.windows.first { ObjectIdentifier($0) == key }
        }
        return nil
    }

    // MARK: - CWD-driven auto-naming (global — AI machinery stays process-wide)

    /// When the anchor tab (first leaf pane's first tab) of a session moves
    /// to a CWD that has a cached name OR matches a project-name rule,
    /// apply the derived name as the session title — but only if the user
    /// hasn't explicitly renamed the session (`titleOverride == true`).
    /// Mirrors the write rule in `renameSession` — only the anchor tab's CWD
    /// drives auto-naming. Cache hits beat project-name extraction so that
    /// a previously-typed rename in this CWD always wins (`#0058` + `#0089`).
    ///
    /// Single-pane sessions also reset to the default `Session N` title
    /// when CWD moves *out* of any project directory (no cache hit, no
    /// project rule match). Multi-pane sessions are skipped entirely —
    /// each pane has its own CWD and picking one would be arbitrary
    /// (`#0213`).
    public func handleWorkingDirectoryChange(forTabID tabID: UUID) {
        // Search across ALL windows — the `sessions` shim resolves to
        // windows[0] only, so using it here would silently skip sessions in
        // every other window (#0248 trigger bug).
        for window in windows {
            for (index, session) in window.sessions.enumerated() {
                let anchorTab = session.tree.root.firstLeafPane.tabs[0]
                guard anchorTab.id == tabID else { continue }
                guard !session.titleOverride else { return }
                guard session.tree.allPanes.count == 1 else { return }
                let cwd = anchorTab.terminal.workingDirectory
                    ?? anchorTab.terminal.configuration.workingDirectory
                guard let cwd, !cwd.isEmpty else { return }
                var resolved = Self.resolveAutoTitle(
                    forCWD: cwd,
                    sessionIndex: index,
                    cache: nameCache,
                    resolver: ProjectNameResolver.shared,
                    nameFromFiles: SettingsPreference.resolvedAutoNameFromFiles()
                )
                if Self.isDefaultSessionTitle(resolved) {
                    // Deterministic chain missed — AI fallback (#0231). A
                    // memoized suggestion stands in for the default directly;
                    // an unknown path kicks off an async request. The settings
                    // toggle (#0233) gates the whole AI step, memo included —
                    // a memoized AI name is still automatic naming.
                    if !SettingsPreference.resolvedAutoNameWithAI() {
                        cancelNameSuggestion(forSessionID: session.id)
                    } else if let memoized = nameSuggestionMemo[cwd] {
                        cancelNameSuggestion(forSessionID: session.id)
                        if let name = memoized {
                            resolved = name
                        }
                    } else {
                        scheduleNameSuggestion(for: session, cwd: cwd)
                    }
                } else {
                    cancelNameSuggestion(forSessionID: session.id)
                }
                guard resolved != session.title else { return }
                logger.info("auto-rename session \(session.title, privacy: .public) -> \(resolved, privacy: .public) for cwd=\(cwd, privacy: .public)")
                session.title = resolved
                return
            }
        }
    }

    private func cancelNameSuggestion(forSessionID sessionID: UUID) {
        guard let inflight = nameSuggestionTasks[sessionID] else { return }
        inflight.task.cancel()
        nameSuggestionTasks[sessionID] = nil
    }

    /// Kicks off the async AI naming request for `cwd`. The deterministic
    /// title has already settled synchronously; the suggestion applies later
    /// only if nothing superseded it (see `applySuggestedName`). The result —
    /// including "no name" — is memoized so repeat visits don't re-prompt.
    private func scheduleNameSuggestion(for session: SessionRuntime, cwd: String) {
        guard let suggester = nameSuggester else { return }
        if let inflight = nameSuggestionTasks[session.id] {
            if inflight.path == cwd { return }
            inflight.task.cancel()
            nameSuggestionTasks[session.id] = nil
        }
        let sessionID = session.id
        let task = Task { [weak self] in
            let raw = await suggester.suggestName(forPath: cwd)
            guard let self, !Task.isCancelled else { return }
            self.nameSuggestionTasks[sessionID] = nil
            let name = raw.flatMap(SessionNameSuggestion.sanitize)
            if self.nameSuggestionMemo.count >= Self.nameSuggestionMemoCap {
                self.nameSuggestionMemo.removeAll(keepingCapacity: true)
            }
            self.nameSuggestionMemo.updateValue(name, forKey: cwd)
            guard let name else { return }
            self.applySuggestedName(name, toSessionID: sessionID, forCWD: cwd)
        }
        nameSuggestionTasks[sessionID] = (path: cwd, task: task)
    }

    /// Applies an AI suggestion only if the world hasn't moved on since the
    /// request was issued: the session still exists, is still single-pane,
    /// the user hasn't renamed it, the anchor cwd is unchanged, and the title
    /// is still the default (no newer resolution superseded the request).
    /// Deliberately never writes `nameCache` and never sets `titleOverride` —
    /// an AI suggestion has the same standing as a rules-derived name: a
    /// later cd re-resolves it and only an explicit user rename is stored.
    private func applySuggestedName(_ name: String, toSessionID sessionID: UUID, forCWD cwd: String) {
        // Search across ALL windows — the `sessions` shim resolves to
        // windows[0] only, so using it here would silently fail for sessions
        // in other windows (#0248).
        let session = windows.lazy.flatMap(\.sessions).first { $0.id == sessionID }
        guard let session else { return }
        guard !session.titleOverride else { return }
        guard session.tree.allPanes.count == 1 else { return }
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        let currentCWD = anchorTab.terminal.workingDirectory
            ?? anchorTab.terminal.configuration.workingDirectory
        guard currentCWD == cwd else { return }
        guard Self.isDefaultSessionTitle(session.title) else { return }
        logger.info("AI auto-name session \(session.title, privacy: .public) -> \(name, privacy: .public) for cwd=\(cwd, privacy: .public)")
        session.title = name
    }

    /// Pure decision function for the single-pane CWD-driven auto-naming
    /// chain: cache hit > project-name extraction > default `Session N`.
    /// The default is the only branch that resets a title when the shell
    /// walks *out* of a project directory (`#0213`). Caller is responsible
    /// for the single-pane and `titleOverride` gates, and for resolving
    /// `nameFromFiles` from settings (#0233) — no `UserDefaults` reads here.
    /// Cache hits stay live with `nameFromFiles` off: they record explicit
    /// user renames, not automatic naming.
    static func resolveAutoTitle(
        forCWD cwd: String,
        sessionIndex: Int,
        cache: SessionNameCache,
        resolver: ProjectNameResolver.Resolver,
        nameFromFiles: Bool = true
    ) -> String {
        if let cachedName = cache.lookup(path: cwd) {
            return cachedName
        }
        if nameFromFiles, let derivedName = resolver.resolve(at: cwd) {
            return derivedName
        }
        return String(localized: "Session \(sessionIndex + 1)")
    }

    public static func isDefaultSessionTitle(_ title: String) -> Bool {
        title.wholeMatch(of: defaultSessionTitlePattern) != nil
    }

    private static let defaultSessionTitlePattern: Regex<Substring> = {
        // swiftlint:disable:next force_try
        try! Regex(#"^Session \d+$"#)
    }()

    // MARK: - Tab-level CWD-driven auto-naming (#0260)

    /// Auto-names a single Tab's chip from its working directory, using the
    /// same on-device suggester and per-cwd memo as session auto-naming
    /// (`handleWorkingDirectoryChange(forTabID:)` above). Runs for every
    /// tab in every pane — unlike session naming there is no multi-pane
    /// ambiguity to dodge (#0213): each tab has its own cwd, so each tab
    /// gets its own suggestion. The sidebar pane row (#0259) shows this
    /// same value for a pane's first tab; see `SessionSidebarView.PaneRow`.
    ///
    /// Never overwrites `tab.titleOverride` — an explicit rename pins the
    /// chip until the user resets it, mirroring the session pin.
    public func updateTabAutoName(for tab: TabRuntime) {
        guard tab.titleOverride == nil else {
            cancelTabNameSuggestion(forTabID: tab.id)
            return
        }
        guard SettingsPreference.resolvedAutoNameWithAI() else {
            cancelTabNameSuggestion(forTabID: tab.id)
            return
        }
        let cwd = tab.terminal.workingDirectory ?? tab.terminal.configuration.workingDirectory
        guard let cwd, !cwd.isEmpty else {
            cancelTabNameSuggestion(forTabID: tab.id)
            if tab.aiSuggestedName != nil {
                tab.aiSuggestedName = nil
            }
            return
        }
        if let memoized = nameSuggestionMemo[cwd] {
            cancelTabNameSuggestion(forTabID: tab.id)
            if tab.aiSuggestedName != memoized {
                tab.aiSuggestedName = memoized
            }
            return
        }
        // Not memoized yet — clear any name left over from a prior cwd so
        // the chip falls through to the deterministic chain (project name /
        // prettified path) while the request is in flight, exactly as
        // session naming lets the deterministic title stand until the AI
        // fallback resolves.
        if tab.aiSuggestedName != nil {
            tab.aiSuggestedName = nil
        }
        scheduleTabNameSuggestion(for: tab, cwd: cwd)
    }

    private func cancelTabNameSuggestion(forTabID tabID: UUID) {
        guard let inflight = tabNameSuggestionTasks[tabID] else { return }
        inflight.task.cancel()
        tabNameSuggestionTasks[tabID] = nil
    }

    private func scheduleTabNameSuggestion(for tab: TabRuntime, cwd: String) {
        guard let suggester = nameSuggester else { return }
        let tabID = tab.id
        if let inflight = tabNameSuggestionTasks[tabID] {
            if inflight.path == cwd { return }
            inflight.task.cancel()
            tabNameSuggestionTasks[tabID] = nil
        }
        let task = Task { [weak self, weak tab] in
            let raw = await suggester.suggestName(forPath: cwd)
            guard let self, !Task.isCancelled else { return }
            self.tabNameSuggestionTasks[tabID] = nil
            let name = raw.flatMap(SessionNameSuggestion.sanitize)
            if self.nameSuggestionMemo.count >= Self.nameSuggestionMemoCap {
                self.nameSuggestionMemo.removeAll(keepingCapacity: true)
            }
            self.nameSuggestionMemo.updateValue(name, forKey: cwd)
            guard let name, let tab else { return }
            self.applySuggestedTabName(name, tab: tab, forCWD: cwd)
        }
        tabNameSuggestionTasks[tabID] = (path: cwd, task: task)
    }

    /// Applies an AI suggestion only if the tab hasn't moved on since the
    /// request was issued: no user rename landed, and the cwd is unchanged.
    /// Never writes `titleOverride` — same standing as session naming, a
    /// later `cd` re-resolves it.
    private func applySuggestedTabName(_ name: String, tab: TabRuntime, forCWD cwd: String) {
        guard tab.titleOverride == nil else { return }
        let currentCWD = tab.terminal.workingDirectory ?? tab.terminal.configuration.workingDirectory
        guard currentCWD == cwd else { return }
        tab.aiSuggestedName = name
    }

    // MARK: - Private helpers

    /// Returns the `WindowRuntime` that owns the session with `sessionID`,
    /// searching across all registered windows. Used by the action shims that
    /// route operations by session ID (rename, remove, clear, duplicate) so
    /// they always target the correct window rather than defaulting to windows[0].
    private func windowOwning(sessionID: UUID) -> WindowRuntime? {
        windows.first { $0.sessions.contains(where: { $0.id == sessionID }) }
    }

    /// #0297's single choke point: every real-tab bell path (BEL, OSC
    /// 9/777, CLI `notify`) — `recordBellTick`, `recordDesktopNotification`,
    /// `recordCLINotification` — calls this exactly once per entry, so
    /// capturing the decision here before the early-return suppression
    /// gates covers all three trigger kinds and every gate (nil notifier,
    /// session mute, the notifications setting, `BellNotifier`'s
    /// frontmost-and-seen check) with one `BellDecisionHistory` record.
    /// `recordFootprintWarning` (#0290's system entry) never calls this
    /// method — it posts via `BellNotifier.postFootprintWarning` directly —
    /// so a system entry can never masquerade as a real-bell decision here.
    ///
    /// Capture is unconditional (no Settings toggle — see
    /// `BellDecisionHistory`'s type doc comment for why) and unconditionally
    /// cheap: two libghostty FFI calls (`foregroundPid`/`ttyName`), a
    /// `UserDefaults` read, `NSApplication.shared.isActive`, and a couple of
    /// linear scans over a Session's Panes/Tabs, all triggered by a bell —
    /// a human-scale, discrete event, not a hot path — so paying this cost
    /// every time, including on the nil-notifier/muted-session cases below
    /// that return early, is negligible.
    private func postNotification(
        for entry: BellFeedEntry,
        at location: WindowRuntime.BellLocation,
        trigger: BellTriggerKind,
        playSound: Bool = true
    ) {
        bellDecisionHistory.record(makeBellDecisionRecord(for: entry, at: location, trigger: trigger))

        guard let notifier else { return }
        guard !location.session.notificationsMuted else { return }
        let paneIndex = (location.session.tree.allPanes.firstIndex { $0.id == location.pane.id } ?? 0) + 1
        let tabIndex = (location.pane.tabs.firstIndex { $0.id == location.tab.id } ?? 0) + 1
        notifier.post(
            for: entry,
            sessionTitle: location.session.title,
            paneIndex: paneIndex,
            tabLabel: Self.tabLabel(for: location.tab, tabIndex: tabIndex),
            playSound: playSound
        )
    }

    /// Override → terminal title → "Tab N" fallback, shared by the real
    /// notification content (`postNotification`) and the #0297 decision
    /// record (`makeBellDecisionRecord`) so the two can never disagree
    /// about what a Tab is called.
    private static func tabLabel(for tab: TabRuntime, tabIndex: Int) -> String {
        if let override = tab.titleOverride, !override.isEmpty {
            return override
        }
        if !tab.terminal.title.isEmpty {
            return tab.terminal.title
        }
        return String(localized: "Tab \(tabIndex)")
    }

    /// Builds the #0297 decision record handed to `bellDecisionHistory
    /// .record(_:)`. `sessionTitle`/`tabLabel`/`message` are truncated to
    /// `BellDecisionFormat.maxFieldLength` here, not just at format time —
    /// see `BellDecisionFormat.truncateForRetention`'s doc comment for why
    /// storing more than that per field is dead weight the ring buffer
    /// would otherwise carry ×`BellDecisionHistory.capacity`, for the
    /// process lifetime, with nothing bounding an OSC 9/777 or CLI
    /// `notify` body upstream.
    /// `forcedOutcome`: #0298's collapsed-repeat path (`postNotification`'s
    /// caller passes `.suppressed(.collapsedIntoUnread)` here rather than
    /// letting this method compute the gate outcome as usual) — a collapsed
    /// repeat never reaches `notifier.post`, so the notifier/mute/settings
    /// gates below were never evaluated for it and reporting their verdict
    /// as this record's outcome would misrepresent what happened. The gate
    /// *facts* (`notifierPresent`, `sessionMuted`, etc.) are still captured
    /// normally either way — only `outcome` is overridden.
    private func makeBellDecisionRecord(
        for entry: BellFeedEntry,
        at location: WindowRuntime.BellLocation,
        trigger: BellTriggerKind,
        forcedOutcome: BellDecisionRecord.Outcome? = nil
    ) -> BellDecisionRecord {
        let tabIndex = (location.pane.tabs.firstIndex { $0.id == location.tab.id } ?? 0) + 1
        let battyActive = NSApplication.shared.isActive
        let systemNotificationsEnabled = SettingsPreference.resolvedSystemNotifications()
        let notifierPresent = notifier != nil
        let sessionMuted = location.session.notificationsMuted
        // hasMessage reads the untruncated entry.message so an
        // all-whitespace-past-maxLength message can't flip empty; a real
        // message truncated to maxLength (>= 1) is never empty either way.
        let hasMessage = entry.message?.isEmpty == false
        return BellDecisionRecord(
            trigger: trigger,
            entryID: entry.id,
            windowID: entry.windowID,
            sessionID: entry.sessionID,
            paneID: entry.paneID,
            tabID: entry.tabID,
            bellTimestamp: entry.timestamp,
            sessionTitle: BellDecisionFormat.truncateForRetention(location.session.title),
            tabLabel: BellDecisionFormat.truncateForRetention(Self.tabLabel(for: location.tab, tabIndex: tabIndex)),
            hasMessage: hasMessage,
            message: entry.message.map { BellDecisionFormat.truncateForRetention($0) },
            battyActive: battyActive,
            entrySeenAtCreation: entry.seen,
            notifierPresent: notifierPresent,
            sessionMuted: sessionMuted,
            systemNotificationsEnabled: systemNotificationsEnabled,
            foregroundPid: location.tab.terminalNSView?.foregroundPid,
            ttyName: location.tab.terminalNSView?.ttyName,
            outcome: forcedOutcome ?? BellDecisionRecord.outcome(
                notifierPresent: notifierPresent,
                sessionMuted: sessionMuted,
                systemNotificationsEnabled: systemNotificationsEnabled,
                battyActive: battyActive,
                entrySeenAtCreation: entry.seen
            )
        )
    }

    /// #0298: called instead of `postNotification` when `entry` collapsed
    /// into an existing unread `BellFeedEntry` rather than becoming its own
    /// row (`BellFeedStore.recordOrCollapse`'s `.collapsed` case). Still
    /// records a #0297 decision — `outcome=suppressed:collapsedIntoUnread`
    /// — so the export accounts for every bell, including ones that never
    /// reached the notifier gates at all, but deliberately never calls
    /// `notifier.post`: the entire point of collapsing is to not re-post a
    /// system notification for a repeat the user hasn't acknowledged yet.
    private func recordCollapsedNotificationDecision(
        for entry: BellFeedEntry,
        at location: WindowRuntime.BellLocation,
        trigger: BellTriggerKind
    ) {
        bellDecisionHistory.record(
            makeBellDecisionRecord(for: entry, at: location, trigger: trigger, forcedOutcome: .suppressed(.collapsedIntoUnread))
        )
    }

    /// Kicks off async AI summarization for a newly-recorded bell entry.
    /// The entry appears in the feed immediately with today's fallback text;
    /// the summary is written back when the model responds. A nil summarizer,
    /// disabled toggle, or model error leaves the entry unchanged.
    private func scheduleSummarization(for entry: BellFeedEntry, tabTitle: String, sessionTitle: String) {
        guard let summarizer = notificationSummarizer else { return }
        guard SettingsPreference.resolvedSummarizeNotificationsWithAI() else { return }
        let entryID = entry.id
        let message = entry.message
        let tabTitleCopy = tabTitle
        let sessionTitleCopy = sessionTitle
        Task { [weak self] in
            let raw = await summarizer.summarize(
                message: message,
                tabTitle: tabTitleCopy.isEmpty ? nil : tabTitleCopy,
                sessionTitle: sessionTitleCopy.isEmpty ? nil : sessionTitleCopy
            )
            guard let self, !Task.isCancelled else { return }
            guard let summary = raw.flatMap(NotificationSummary.sanitize) else { return }
            self.bellFeed.updateSummary(summary, forEntryID: entryID)
        }
    }
}
