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
    /// Owns the footprint sampling timer (#0290). Constructed in `init` from
    /// this store's `preferences` — never started here, though: `start()` is
    /// production-only wiring (`BattyAppDelegate`), so constructing an
    /// `AppStateStore` on its own never spins up a background sampling loop.
    @ObservationIgnored public let footprintMonitor: FootprintMonitor
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
    /// Where this store's settings-gated code paths read their toggles
    /// from: session/tab auto-naming (`handleWorkingDirectoryChange`,
    /// `updateTabAutoName`), notification summarization
    /// (`scheduleSummarization`), the system-notifications gate recorded by
    /// `makeBellDecisionRecord`, cursor/blink/font-size appearance applied by
    /// `applyAppearanceToAllSurfaces`, the footprint soft limit `init` hands
    /// to `footprintMonitor` (`FootprintMonitor(defaults:)`, read on each
    /// sample via `resolvedFootprintSoftLimitBytes(defaults:)`), and the
    /// theme resolution this `init` seeds `themeChrome` from
    /// (`ThemePreference.activeTheme(isDark:defaults:)`) and that
    /// `applyGlobalThemeForCurrentAppearance`/`applyActiveSessionTheme`
    /// re-resolve on appearance/session changes.
    /// `PasteDispatcher.handlePasteRequest` and `QuitConfirmation
    /// .shouldQuitOrPrompt(store:)` (called from `Batty/BattyApp.swift`)
    /// both take a store and read its `preferences` internally.
    /// `QuitConfirmation.windowNeedsConfirmClose(window:defaults:)` instead
    /// takes a raw `UserDefaults`; its only caller, `WindowDelegate` in
    /// `Views/RootWindowView.swift`, passes the owning store's `preferences`.
    /// This list is not guaranteed exhaustive against future additions.
    ///
    /// Defaults to `.standard` — an init parameter, not a settable property,
    /// so nothing after construction can swap a store's preferences source
    /// out from under the paths above. Production never passes anything
    /// else. Unit tests that exercise a settings-gated path pass their own
    /// `TestDefaults().defaults` (`Support/TestDefaults.swift`) instead,
    /// since every concurrent `./build.sh unit` run on the machine shares
    /// `.standard` through one `cfprefsd` (#0426).
    @ObservationIgnored public let preferences: UserDefaults

    /// Release gates. Views, commands, the palette and XPC read this rather
    /// than resolving flags themselves. See `docs/feature-flags.md`.
    @ObservationIgnored public let featureFlags: FeatureFlags

    /// Nil while `featureFlags.projects` is off; the store, and so the
    /// `projects.json` path, is never touched in that case. Built on first
    /// access when on.
    public var projectStore: ProjectStore? {
        guard featureFlags.projects else { return nil }
        if let existing = projectStoreStorage { return existing }
        let store = ProjectStore(fileURL: projectsFileURL)
        projectStoreStorage = store
        return store
    }
    @ObservationIgnored private var projectStoreStorage: ProjectStore?
    @ObservationIgnored private let projectsFileURL: URL?
    @ObservationIgnored var pendingStartupOpens: [UUID: PendingStartupOpen] = [:]
    /// Test seam: observes every request to bring a Window forward, including
    /// ones that find no `NSWindow` to act on (unit tests), so tests can pin
    /// when an activation is asked for. Nil in production.
    @ObservationIgnored var windowActivationObserver: ((WindowRuntime) -> Void)?
    /// Test seam: stands in for the Tab's terminal as the target of startup
    /// commands. Nil in production.
    @ObservationIgnored var startupInputSinkFactory: ((TabRuntime) -> any StartupInputSink)?

    /// Test-only bookkeeping for `scheduleSummarization`'s in-flight `Task`s,
    /// keyed by `BellFeedEntry.id`. See `summarizationTaskForTesting(entryID:)`.
    @ObservationIgnored private var summarizationTasksForTesting: [UUID: Task<Void, Never>] = [:]
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
    /// Content windows in the order they most recently became key, oldest
    /// first, most recent last (#0439) — an array, not a single `WindowID?`,
    /// so closing the most-recently-key window falls back to the window key
    /// before it, not straight to the oldest. Fed by
    /// `noteContentWindowBecameKey(_:)`. `@ObservationIgnored` for the same
    /// reason as `nsWindowMap`: populated from AppKit callbacks, not
    /// SwiftUI-update code.
    @ObservationIgnored private var recentlyKeyWindowIDs: [WindowID] = []
    /// Token for the app-wide `NSWindow.didBecomeKeyNotification` observer
    /// that feeds `recentlyKeyWindowIDs`. Removed in `deinit` so a store
    /// discarded in a test doesn't leave a dangling observer on the shared
    /// `NotificationCenter`. `nonisolated(unsafe)`: a nonisolated `deinit`
    /// can't otherwise read a main-actor-isolated property whose type (`any
    /// NSObjectProtocol`) the compiler won't infer `Sendable` — safe because
    /// this property is only ever mutated on the main thread and only read
    /// in `deinit`, after every other reference is already gone.
    @ObservationIgnored private nonisolated(unsafe) var keyWindowObservation: NSObjectProtocol?
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

    /// The `WindowID` a New Window action must present. While no content
    /// window is registered it is `initialWindowID` — the runtime `init`
    /// already seeded — so opening the first window reuses it instead of
    /// creating a phantom second runtime (#0251). Once a content window is
    /// registered every call gets a fresh id. `openWindow(value:)` focuses an
    /// existing window presenting the same value rather than opening another,
    /// so presenting `initialWindowID` for a window that already shows it focuses
    /// that window. `LaunchWindowGuard` additionally checks for an existing
    /// SwiftUI content window before calling this (#0444).
    public func windowIDForNewWindow() -> WindowID {
        registeredContentWindowCount == 0 ? initialWindowID : WindowID()
    }

    /// True when a launch has finished with no content window registered, so
    /// the app must open one itself. AppKit can mark a launch as "state
    /// restored" and make SwiftUI skip its default window, leaving a menu bar
    /// and nothing else (#0444).
    public var launchNeedsContentWindow: Bool {
        registeredContentWindowCount == 0
    }

    /// Returns the `WindowRuntime` for `windowID`, creating one lazily if
    /// it does not yet exist. This is the single path for launch, New Window,
    /// and restoration (currently disabled) — all converge here so a new scene and a new runtime
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
    /// window have been released. Safe to call with an unknown id. Also
    /// prunes `id` from the most-recently-key order (#0439) — belt-and-
    /// braces alongside `unregisterNSWindow`'s own pruning, since
    /// `WindowDelegate.windowWillClose` calls both in the same teardown and
    /// a test may call this one alone.
    public func removeWindow(id windowID: WindowID) {
        pruneRecentlyKeyWindowID(windowID)
        for request in windows.first(where: { $0.id == windowID })?.pendingStartupTrusts ?? [] {
            cancelStartupTrust(requestID: request.id)
        }
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
    /// This is deliberately not the `Task`-hop AGENTS.md and the #0229
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
        // #0361: ground truth about *this* process's own bundle, so a CLI
        // that connects to an already-registered endpoint (no bundle
        // resolution on its side at all) can still tell which on-disk app
        // it's talking to — the diagnostic gap that made the ambiguous
        // bundle-identifier bug undiagnosable in the first place.
        let bundleInfo = Bundle.main.infoDictionary
        let appVersion = (bundleInfo?["CFBundleShortVersionString"] as? String)
            ?? (bundleInfo?["CFBundleVersion"] as? String)
            ?? "unknown"
        return StatusPayload(
            pid: ProcessInfo.processInfo.processIdentifier,
            uptimeSeconds: Date().timeIntervalSince(launchDate),
            windowCount: windows.count,
            sessionCount: totalSessions,
            tabCount: totalTabs,
            bundlePath: Bundle.main.bundleURL.path,
            appVersion: appVersion
        )
    }

    // MARK: - XPC topology (#0274)

    /// Full topology for the `list` XPC verb: every window, its sessions,
    /// and each session's pane/tab tree. Purely a read over `windows` —
    /// see `TopologyPayloadBuilder.swift` for the walk. Never touches
    /// `selectedSessionID`, `focusedPaneID`, or `activeTabID`, so listing a
    /// background session's topology cannot steal focus or switch the
    /// active session.
    


    public func topologyPayload(includeDimensions: Bool = false) -> TopologyPayload {
        TopologyPayload(
            pid: ProcessInfo.processInfo.processIdentifier,
            windows: windows.map { $0.topologyPayload(includeDimensions: includeDimensions) }
        )
    }





    /// The slice for a single session, for the `sessionInfo` XPC verb.
    ///
    /// `sessionID` resolves an explicit target across *all* windows (not
    /// just the key window) so a caller in a background session can ask
    /// about itself. `sessionID == nil` falls back to the focused session —
    /// resolved through `defaultTargetWindow()`'s single policy (#0439: the
    /// key content window, then the most recently key one, then the newest
    /// registered one, then `windows.first`), then that window's selected or
    /// first session. This is the seam #0257's `BATTY_SESSION_ID` env-var
    /// fallback slots into later: the eventual order is `--session` flag →
    /// `BATTY_SESSION_ID` → focused session, of which only the first and
    /// last exist today — the middle branch is #0257's to add, and it
    /// inserts here without changing this method's signature or the reply
    /// schema.
    ///
    /// Returns `nil` when an explicit `sessionID` doesn't resolve to any
    /// session in any window, or when there is no session to fall back to
    /// (no windows, or a window with an empty session list — both
    /// unreachable in practice since every window seeds one session, but
    /// handled rather than force-unwrapped).




    public func sessionInfoPayload(sessionID: UUID? = nil, includeDimensions: Bool = false) -> TopologySessionPayload? {
        if let sessionID {
            for window in windows {
                if let session = window.sessions.first(where: { $0.id == sessionID }) {
                    return session.topologyPayload(isActive: window.selectedSessionID == session.id, includeDimensions: includeDimensions)
                }
            }
            return nil
        }
        guard let window = defaultTargetWindow(),
              let session = window.selectedSession ?? window.sessions.first
        else {
            return nil
        }
        return session.topologyPayload(isActive: window.selectedSessionID == session.id, includeDimensions: includeDimensions)
    }




    /// The session to target when the XPC `session focus` verb (#0381)
    /// receives no explicit `--session` id and no `BATTY_SESSION_ID` env —
    /// the same "focused element" fallback `sessionInfoPayload(sessionID:
    /// nil)` and `focusedPaneIDFallback()` use, one tier up from the pane
    /// fallback (the session itself, not its focused pane). Window
    /// resolution goes through `defaultTargetWindow()` (#0439). `nil` only
    /// when there is no window/session to fall back to (unreachable in
    /// practice — every window seeds one session — but handled rather than
    /// force-unwrapped).
    public func focusedSessionIDFallback() -> UUID? {
        guard let window = defaultTargetWindow(),
              let session = window.selectedSession ?? window.sessions.first
        else { return nil }
        return session.id
    }

    // MARK: - XPC pane split (#0282)

    /// The pane to target when an XPC mutation verb (`pane split` #0282,
    /// later `pane close` #0283) receives no explicit pane id — the same
    /// "focused element" fallback `sessionInfoPayload(sessionID: nil)` uses
    /// one level up, resolved to the target *session*'s `focusedPaneID`
    /// rather than the session itself. Window resolution goes through
    /// `defaultTargetWindow()` (#0439). `nil` only when there is no
    /// window/session to fall back to (unreachable in practice — every
    /// window seeds one session — but handled rather than force-unwrapped).
    public func focusedPaneIDFallback() -> UUID? {
        guard let window = defaultTargetWindow(),
              let session = window.selectedSession ?? window.sessions.first
        else { return nil }
        return session.tree.focusedPaneID
    }

    /// The tab to target when the XPC `notify` verb (#0284) receives no
    /// explicit `--tab` id and no `BATTY_TAB_ID` env — one tier below
    /// `focusedPaneIDFallback()`, since a `BellFeedEntry` needs a real tab,
    /// not merely a real pane: the focused pane's active tab. `nil` when
    /// there is no window/session/pane to fall back to (unreachable in
    /// practice, mirroring `focusedPaneIDFallback()`'s own note), **and
    /// also when the focused pane is not `.terminal`-kind** (#0332): a
    /// non-terminal pane's `activeTabID` names a structural placeholder Tab
    /// no view ever renders (`PaneRuntime.kind`'s doc comment), so filing a
    /// `BellFeedEntry` against it would be visible nowhere and its unseen
    /// counts would never clear (`WindowRuntime.markActiveTabSeen()` only
    /// walks tabs a session's tree actually surfaces to the user). Callers
    /// that receive `nil` here fall back to the CLI's existing "no tab to
    /// target" failure reply (`AppXPCService`'s notify handler) rather than
    /// silently accepting a tab that can never be seen or cleared.
    public func focusedTabIDFallback() -> UUID? {
        guard let paneID = focusedPaneIDFallback(),
              let window = defaultTargetWindow()
        else { return nil }
        for session in window.sessions {
            if let pane = session.tree.allPanes.first(where: { $0.id == paneID }) {
                guard pane.kind == .terminal else { return nil }
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
    /// `contentFactory` is `nil` by default (not the concrete
    /// `PaneRuntime.makeContent`), forwarded unchanged from whatever the
    /// caller passed — see `SplitTree.makePane`'s doc comment for why `nil`
    /// specifically (not "the production default") has to survive all the
    /// way down to the layer that can resolve a `.gitStatus` pane's
    /// directory, so an explicit test override isn't silently shadowed by
    /// path resolution.
    ///
    /// This verb is exactly the case #0349 named: it can target a Pane in a
    /// *background* Session (never touches `selectedSessionID`, per the
    /// paragraph above), so a non-terminal Pane created here must not start
    /// its watcher/poller/subprocess if `session` isn't the owning window's
    /// selected one — computed here, once, since this is the layer that
    /// actually has both `window.selectedSessionID` and `session.id` in
    /// hand, and threaded down through `SplitTree.splitPane`'s own
    /// `isSessionSelected` parameter to `PaneRuntime.init`'s `setUp(visible:)`.
    @discardableResult
    public func splitPane(
        id paneID: UUID,
        direction: SplitDirection,
        command: String? = nil,
        kind: PaneContentKind = .terminal,
        processStatusPid: Int32? = nil,
        path: String? = nil,
        contentFactory: (@MainActor (PaneContentKind) -> (any PaneContentLifecycle)?)? = nil
    ) -> UUID? {
        for window in windows {
            if let session = window.sessions.first(where: { $0.tree.root.contains(paneID: paneID) }) {
                let isSessionSelected = window.selectedSessionID == session.id
                if let newPane = session.tree.splitPane(id: paneID, direction: direction, command: command, kind: kind, processStatusPid: processStatusPid, path: path, contentFactory: contentFactory, isSessionSelected: isSessionSelected) {
                    let event = WatchEventPayload(type: "pane_split", sessionID: session.id, targetPaneID: newPane.id)
                    AppEventWatcher.shared.send(eventType: event.type, payload: event)

                    return newPane.id
                }
            }
        }
        return nil
    }

    // MARK: - XPC pane split `--unique` (#0383)

    /// The "find" half of `pane split --view <kind> --unique`: a visible
    /// Pane of `kind` already in `paneID`'s owning Session, or `nil` when
    /// none exists — `AppXPCService` falls through to `splitPane` unchanged
    /// when this returns `nil`.
    ///
    /// Matches `PaneRuntime.kind` directly — the same field #0379 exposes
    /// over the wire as `TopologyPanePayload.kind` (`docs/pane-kinds.md`
    /// §5's "one string, three call sites") — rather than growing a second
    /// way to ask what kind a Pane is. Unlike that wire field,
    /// `PaneRuntime.kind` is never optional: it has been a concrete,
    /// always-populated `PaneContentKind` since #0315, well before #0379
    /// added the wire projection for stale-reader compatibility. The
    /// "kind unknown" question #0383 raises for a stale reader therefore
    /// does not apply here — this only ever runs inside a live app process
    /// comparing its own Panes' real, concrete kinds, never round-tripping
    /// through the optional payload type.
    ///
    /// Scope is the target Session, not the Window and not the app
    /// (#0383's pinned match rule) — mirrors `splitPane`'s own
    /// same-Session resolution via `paneID`. Hidden Panes never match
    /// (`SplitTree.visiblePanes`, not `.allPanes`): a hidden Pane isn't
    /// "showing," and `pane show` (#0382) is the verb for un-hiding one.
    /// `viewOptions` differences (a different `--path`/`--pid`) never
    /// defeat the match — the first visible Pane of `kind`, in the
    /// Session's existing depth-first pane ordering, wins deterministically
    /// when more than one exists.
    ///
    /// Always `nil` for `kind == .terminal` — there is no sensible "the
    /// terminal Pane" to find (#0383's issue text). The CLI already
    /// rejects `--unique` without a non-terminal `--view` before this ever
    /// round-trips over XPC, but the invariant belongs here too: without
    /// it, `.terminal` would match the *first visible terminal Pane in the
    /// Session*, almost always the split's own source Pane, so `pane
    /// split --view terminal --unique` (or a caller that bypasses the CLI
    /// check some other way) would silently hand back the caller's own
    /// pane id instead of ever splitting.
    public func findUniquePane(paneID: UUID, kind: PaneContentKind) -> UUID? {
        guard kind != .terminal else { return nil }
        for window in windows {
            if let session = window.sessions.first(where: { $0.tree.root.contains(paneID: paneID) }) {
                return session.tree.visiblePanes.first { $0.kind == kind }?.id
            }
        }
        return nil
    }

    // MARK: - XPC pane close (#0283)

    /// Ends every Tab's Terminal Session in `paneID` and removes its region
    /// from its owning session's split tree — #0283's XPC `pane close`
    /// verb. This method is XPC-only: the non-terminal Pane header's close
    /// button (#0378's `PaneView.paneCloseButton`) calls
    /// `closeNonTerminalPane(id:)` below instead, not this one, so it never
    /// reports a GUI click as `fromCli: true`.
    /// Searches every window's every session, same as `splitPane`, so a
    /// background-session target resolves identically to a foreground one;
    /// the actual mutation happens in `WindowRuntime.closePane`, which
    /// never touches `selectedSessionID` unless the closed pane emptied
    /// its own session (in which case `removeSession`'s existing,
    /// already-safe "only reassign if the removed session was selected"
    /// behavior applies).
    ///
    /// Refuses (`.refusedLastPane`) rather than closing the app's very last
    /// pane across every window: see `PaneCloseOutcome.refusedLastPane` — an
    /// unattended XPC caller must not have a one-command path into #0217's
    /// silent-quit cascade. There is still no UI path that lets the caller
    /// *confirm and proceed* past a refusal outcome
    /// (`.needsConfirmation`/`.refusedLastPane`) — this verb surfaces the
    /// refusal and stops, rather than bypassing the guard or force-closing.
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
            // #0396: this verb is XPC-only (see the doc comment above) — a
            // pane close that empties its Session is CLI-origin, not the
            // GUI/PTY-origin default `WindowRuntime.closePane` otherwise
            // assumes.
            return window.closePane(id: paneID, refuseIfAppsLastPane: totalPanes == 1, fromCli: true)
        }
        return .unknownPane
    }

    // MARK: - GUI non-terminal pane close (#0378)

    /// The GUI counterpart to `closePane(id:)` above: closes a non-terminal
    /// Pane on behalf of a mouse click on `PaneView.paneCloseButton`, the
    /// close control in the non-terminal Pane header's top-left corner.
    /// Finds the pane's owning window the same way `closePane(id:)` does,
    /// then delegates to `WindowRuntime.closeNonTerminalPane(_:)` — the
    /// same method ⌘W on a non-terminal pane calls
    /// (`closeFocusedTab()`/`requestCloseFocusedTab()`) — so a mouse click
    /// and ⌘W agree on both `refuseIfAppsLastPane: false` (#0334's
    /// contract; unlike `closePane(id:)` above, which refuses the app's
    /// last pane) and `fromCli: false` (#0396; unlike `closePane(id:)`
    /// above, which is XPC-only and always passes `true`).
    @discardableResult
    public func closeNonTerminalPane(id paneID: UUID) -> PaneCloseOutcome {
        for window in windows where window.sessions.contains(where: { $0.tree.root.contains(paneID: paneID) }) {
            return window.closeNonTerminalPane(paneID)
        }
        return .unknownPane
    }

    // MARK: - XPC session close (#0382)

    /// Outcome of `closeSessionForXPC(id:)` — the app-side source of the
    /// XPC `session close` verb. Mirrors `PaneCloseOutcome`'s shape one
    /// tier up.
    public enum SessionCloseOutcome: Equatable, Sendable {
        /// The session was closed: every Tab's Terminal Session across its
        /// panes ended and the session left its window.
        case closed
        /// No session with that id exists in any window — the
        /// stale/unknown-id case `AppXPCService` turns into a failure
        /// reply (CLI exit `4`).
        case unknownSession
        /// At least one Tab across the session's panes has a process
        /// libghostty reports as still needing confirmation to close
        /// (`TerminalViewState.needsConfirmClose`) — the session-level
        /// counterpart of `PaneCloseOutcome.needsConfirmation` (#0283):
        /// there is no UI to confirm over XPC, so the close is refused
        /// rather than silently bypassing the guard the user configured
        /// or force-closing behind their back. The Sidebar's own "Close"
        /// control now sweeps the same guard via `WindowRuntime
        /// .requestRemoveSession(id:)` (#0396) and raises a confirmation
        /// dialog instead of refusing outright — the XPC verb stays
        /// stricter because it is unattended and has no UI to raise that
        /// dialog through. No `--force` flag exists to bypass this
        /// (#0382's pinned decision, following #0283's, not reopened by
        /// #0396).
        ///
        /// **Unreachable against a real process today, same as
        /// `PaneCloseOutcome.needsConfirmation` one tier down**:
        /// `TerminalViewState+Polyfill.swift` hard-codes
        /// `needsConfirmClose` to an unconditional `false` pending an
        /// upstream libghostty-spm change, so this branch cannot fire
        /// against a live surface yet, regardless of caller
        /// (`WindowRuntime.requestCloseFocusedTab()`'s doc comment notes
        /// the same limitation honestly for its own confirmation gate).
        /// It is, however, unit-testable as of #0398:
        /// `TabRuntime.needsConfirmCloseOverride` lets a test force a Tab
        /// to report busy without a live surface, so
        /// `AppStateStoreCloseSessionForXPCTests` exercises this branch
        /// directly. The logic here is correct for the day the polyfill is
        /// removed: it scans every Tab across the session's Panes
        /// (`allPanes.flatMap(\.tabs)`) and refuses before mutating
        /// anything.
        case needsConfirmation
        /// Closing would leave the app with zero sessions across every
        /// window — the session-level counterpart of `PaneCloseOutcome
        /// .refusedLastPane`. An unattended XPC caller must not have a
        /// one-command path into #0217's silent-quit cascade.
        case refusedLastSession
    }

    /// `session close` (#0382): ends every Tab's Terminal Session across
    /// `sessionID`'s panes and removes the session — reusing this class's
    /// own `removeSession(id:)` for the actual mutation, wrapped with the
    /// same refusal shape `closePane(id:)` already applies one tier down:
    /// refuse rather than close when a Tab needs confirmation XPC has no
    /// UI to give, and refuse rather than leave the app with zero
    /// sessions.
    ///
    /// **#0396 update:** `session_destroyed` now emits from
    /// `WindowRuntime.removeSession(id:fromCli:)` itself — the single
    /// choke point every `removeSession`-based removal path funnels
    /// through (this verb, the Sidebar's "Close" control via
    /// `requestRemoveSession`, and the `closeTab`/`closePane` cascades) —
    /// rather than only from this `AppStateStore` wrapper. This call
    /// passes `fromCli: true` so the event correctly reports XPC origin,
    /// matching `focusSessionForXPC`/`focusPaneForXPC`/`focusTabForXPC`'s
    /// existing convention.
    ///
    /// **Still not universal**: closing a whole `NSWindow` (red button,
    /// ⌘⇧W) never calls `removeSession` at all —
    /// `RootWindowView.windowWillClose` tears the window down and calls
    /// `removeWindow(id:)`, which does `windows.removeAll { ... }`
    /// directly, dropping every Session the window held with no
    /// `session_destroyed` for any of them. A `batty watch` consumer must
    /// not assume Session removal is fully covered; this remaining gap is
    /// left to #0145 (or a follow-up) rather than decided here.
    ///
    /// Never touches `selectedSessionID` beyond what `removeSession`
    /// itself already does (reassigning selection only when the *closed*
    /// session was the one selected) — mutating a background target must
    /// not steal focus or switch the active session (#0257).
    @discardableResult
    public func closeSessionForXPC(id sessionID: UUID) -> SessionCloseOutcome {
        guard let window = windowOwning(sessionID: sessionID),
              let session = window.sessions.first(where: { $0.id == sessionID })
        else { return .unknownSession }
        if session.tree.allPanes.flatMap(\.tabs).contains(where: { $0.needsConfirmClose }) {
            logger.notice("closeSessionForXPC: refused session=\(sessionID, privacy: .public) reason=needs-confirmation")
            return .needsConfirmation
        }
        let totalSessions = windows.reduce(0) { $0 + $1.sessions.count }
        guard totalSessions > 1 else {
            logger.notice("closeSessionForXPC: refused session=\(sessionID, privacy: .public) reason=last-session-in-app")
            return .refusedLastSession
        }
        removeSession(id: sessionID, fromCli: true)
        return .closed
    }

    /// Registers the association between an `NSWindow` and its `WindowID`.
    /// Called from `RegistrarNSView.viewDidMoveToWindow` (`WindowIDRegistrar`'s
    /// backing view) synchronously, as soon as the view is attached to its
    /// window — not deferred off the update pass (#0437). Safe to call
    /// multiple times — idempotent per window.
    ///
    /// **Backstop for #0439.** If `nsWindow` is already key at registration
    /// time — `viewDidMoveToWindow` can run after AppKit has already made the
    /// window key, e.g. a window shown and activated in the same run-loop
    /// turn — this also records it in `recentlyKeyWindowIDs` directly,
    /// rather than waiting for a `didBecomeKeyNotification` that already
    /// fired before the window was registered and so was filtered out by
    /// `handleWindowDidBecomeKey`'s `nsWindowMap` lookup.
    public func registerNSWindow(_ nsWindow: NSWindow, for windowID: WindowID) {
        let wasNew = nsWindowMap[ObjectIdentifier(nsWindow)] == nil
        nsWindowMap[ObjectIdentifier(nsWindow)] = windowID
        if wasNew {
            logger.debug("registerNSWindow: windowID=\(windowID.value, privacy: .public) registeredContentWindows=\(self.nsWindowMap.count, privacy: .public)")
        }
        if nsWindow.isKeyWindow {
            noteContentWindowBecameKey(windowID)
        }
    }

    /// Removes a closed window from the registry. Called from the window's
    /// NSWindowDelegate `windowWillClose` path after teardown (releasing
    /// tabs, host). Triggers app termination when the last content window
    /// has been closed. Also prunes the closed window from
    /// `recentlyKeyWindowIDs` (#0439) — resolved via `nsWindowMap` before
    /// that entry is removed, since a `WindowID` doesn't derive from the
    /// `NSWindow` any other way.
    public func unregisterNSWindow(_ nsWindow: NSWindow) {
        if let windowID = nsWindowMap[ObjectIdentifier(nsWindow)] {
            pruneRecentlyKeyWindowID(windowID)
        }
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

    /// Records that `id`'s content window just became key — the single
    /// write path for `recentlyKeyWindowIDs` (#0439). Moves `id` to the most
    /// recent position rather than appending a duplicate. Pure and total —
    /// no `NSWindow`/`NSApp` reads — so tests drive it directly, since
    /// `NSApp.keyWindow` can't be controlled headlessly (`CrossWindowBehaviorTests`'
    /// documented finding). Called from `handleWindowDidBecomeKey(_:)` and,
    /// as a backstop, from `registerNSWindow` when the window is already key
    /// at registration.
    func noteContentWindowBecameKey(_ id: WindowID) {
        recentlyKeyWindowIDs.removeAll { $0 == id }
        recentlyKeyWindowIDs.append(id)
    }

    /// Test seam (#0439): lets `DefaultTargetWindowTests` assert pruning
    /// actually shrinks `recentlyKeyWindowIDs`, since `defaultTargetWindow()`'s
    /// own registered-id filter already makes a stale, unpruned entry
    /// harmless to *resolution* — a resolution-only test can't tell "pruned"
    /// from "merely filtered out at read time" apart.
    var recentlyKeyWindowIDsCountForTesting: Int { recentlyKeyWindowIDs.count }

    /// Removes `id` from the most-recently-key order, e.g. once its window
    /// has closed. No-op if `id` isn't tracked. Private: the only callers are
    /// `unregisterNSWindow` and `removeWindow(id:)`, which both run on real
    /// window-close paths; tests exercise pruning through those, not this
    /// helper directly, so the removal behavior is verified against the
    /// production call sites rather than a copy of it.
    private func pruneRecentlyKeyWindowID(_ id: WindowID) {
        recentlyKeyWindowIDs.removeAll { $0 == id }
    }

    /// `NSWindow.didBecomeKeyNotification` handler, installed app-wide
    /// (`object: nil`) in `init`. Filters through `nsWindowMap` so only
    /// content windows feed `recentlyKeyWindowIDs` — Settings, Help, and
    /// panels becoming key must not perturb the order (#0439).
    private func handleWindowDidBecomeKey(_ nsWindow: NSWindow) {
        guard let windowID = nsWindowMap[ObjectIdentifier(nsWindow)] else { return }
        noteContentWindowBecameKey(windowID)
    }

    /// Single policy resolver for every no-target Window fallback (#0439):
    /// the window a menu command, CLI verb, command-palette action, or
    /// `batty <path>` URL should act on when the request names no explicit
    /// Window/Session/Pane/Tab. Documented order:
    ///
    /// 1. The currently key content window (`keyWindowRuntime()`).
    /// 2. The most recently key registered content window
    ///    (`recentlyKeyWindowIDs`, filtered to windows still registered).
    /// 3. The newest registered content window (`windows`' append order,
    ///    filtered to registered ids) — the "most recently created"
    ///    tie-breaker #0437 introduced, now reached only when no window has
    ///    ever been key.
    /// 4. `windows.first` — the headless/unit-test last resort, where no
    ///    `NSWindow` has registered at all.
    ///
    /// `keyWindowOrFirstRegistered()`, `sessionInfoPayload(sessionID: nil)`,
    /// `focusedSessionIDFallback()`, `focusedPaneIDFallback()`,
    /// `focusedTabIDFallback()`, and `addSession` all call this directly, so
    /// the policy exists in exactly one expression instead of each of those
    /// independently choosing a fallback (the #0439 defect: three different
    /// fallbacks disagreed on which window "no target" meant).
    public func defaultTargetWindow() -> WindowRuntime? {
        if let key = keyWindowRuntime() { return key }
        let registeredIDs = Set(nsWindowMap.values)
        if let recentID = recentlyKeyWindowIDs.last(where: { registeredIDs.contains($0) }),
           let recent = windows.first(where: { $0.id == recentID }) {
            return recent
        }
        if let newest = windows.last(where: { registeredIDs.contains($0.id) }) {
            return newest
        }
        return windows.first
    }

    /// The `WindowRuntime` that `BattyCommands.keyWindow` targets. Delegates
    /// to `defaultTargetWindow()` (#0439) — kept as its own named entry point
    /// because `BattyCommands`, `CommandPaletteView`, and the `AppStateStore`
    /// action shims below already refer to it by this name, and because
    /// `Commands` bodies can't be unit-tested directly
    /// (`docs/swiftui-observation-rules.md`'s Commands-body caution), so this
    /// remains the closest testable seam to `BattyCommands.keyWindow` without
    /// re-typing its expression into a test. Despite the name, this no
    /// longer means "first registered" specifically — see
    /// `defaultTargetWindow()`'s doc comment for the full order.
    public func keyWindowOrFirstRegistered() -> WindowRuntime? {
        defaultTargetWindow()
    }

    /// Whether `window` is the Project Editor, judged after walking up from a
    /// sheet to the window it hangs from, so a dialog over the editor counts
    /// as the editor. Matches on the editor's window identifier, so it never
    /// constructs the editor's controller; that window exists only with the
    /// Projects flag on.
    static func isProjectEditorWindow(_ window: NSWindow?) -> Bool {
        guard var current = window else { return false }
        while let parent = current.sheetParent { current = parent }
        return current.identifier?.rawValue == ProjectEditorWindowController.windowIdentifier
    }

    /// True while the Project Editor is the key window.
    public var projectEditorIsKey: Bool {
        Self.isProjectEditorWindow(NSApplication.shared.keyWindow)
    }

    /// The Window that menu actions on Sessions, Panes and Tabs act on:
    /// `defaultTargetWindow()`, except nil while the Project Editor or the
    /// Open Project picker is key. `BattyShortcuts` declines chords there, so
    /// without this the menu item would run against the content window behind
    /// the editor. The picker's Cmd-N (New Project) and Cmd-E (Edit) are also
    /// New Session and Pane > Open View > System Metrics, and must never act on the
    /// content window behind the sheet. Use it inside
    /// action closures only; enablement is computed from
    /// `defaultTargetWindow()`. XPC and CLI paths keep using
    /// `defaultTargetWindow()`.
    public func menuTargetWindow(projectEditorIsKey: Bool? = nil, projectPickerIsKey: Bool? = nil) -> WindowRuntime? {
        let editorKey = projectEditorIsKey ?? self.projectEditorIsKey
        let pickerKey = projectPickerIsKey ?? self.projectPickerIsKey
        return editorKey || pickerKey ? nil : defaultTargetWindow()
    }

    /// Whether `window` is the Open Project picker's sheet, which tags its
    /// own window with `ProjectPickerView.windowIdentifier`.
    static func isProjectPickerWindow(_ window: NSWindow?) -> Bool {
        window?.identifier?.rawValue == ProjectPickerView.windowIdentifier
    }

    /// True while the Open Project picker is the key window. Its Cmd-N means
    /// New Project, so the File menu's New Session (also Cmd-N) must not
    /// act behind it if the menu ever sees the chord first.
    public var projectPickerIsKey: Bool {
        Self.isProjectPickerWindow(NSApplication.shared.keyWindow)
    }

    /// Whether the lazily built `ProjectStore` exists. Lets tests show a
    /// flag-off code path never constructed it.
    var projectStoreIsConstructed: Bool { projectStoreStorage != nil }

    /// The Terminal Session tab safe to target for tab-scoped Terminal
    /// actions dispatched app-wide (paste, "exit\n" injection): the key
    /// content window's focused pane's active tab, resolved through
    /// `SessionRuntime.focusedTerminalPane` so a non-terminal focused
    /// pane's structural placeholder tab (`PaneRuntime.kind`'s doc comment)
    /// never becomes a target. `nil` for that case as well as for the
    /// ordinary "no window" / "no selected session" ones.
    ///
    /// `ExitDispatcher.sendExit` and `PasteDispatcher.handlePasteRequest`/
    /// `.confirm` both resolve their target through this single property.
    /// Before #0332 each dispatcher hand-copied this expression; one copy
    /// (`PasteDispatcher`'s) drifted to resolve through plain `focusedPane`
    /// instead of `focusedTerminalPane`, silently reintroducing the
    /// structural-placeholder hazard for Cmd-V while `ExitDispatcher`'s own
    /// doc comment kept asserting the two "mirror exactly." One
    /// implementation, called from both sites, is what makes that claim
    /// true rather than merely stated.
    public var focusedTerminalTab: TabRuntime? {
        focusedTerminalTab(projectEditorIsKey: nil)
    }

    /// Nil while the Project Editor is key (see `menuTargetWindow`), so
    /// Paste and Exit Shell leave the Terminal alone then.
    func focusedTerminalTab(projectEditorIsKey: Bool?) -> TabRuntime? {
        menuTargetWindow(projectEditorIsKey: projectEditorIsKey)?.selectedSession?.focusedTerminalPane?.activeTab
    }

    // MARK: - Init

    public init(
        sessions: [SessionRuntime] = [],
        bellFeed: BellFeedStore = BellFeedStore(),
        nameCache: SessionNameCache = SessionNameCache(),
        notifier: BellNotifying? = nil,
        preferences: UserDefaults = .standard,
        featureFlags: FeatureFlags = .resolved(),
        projectsFileURL: URL? = nil
    ) {
        self.projectsFileURL = projectsFileURL
        self.bellFeed = bellFeed
        self.nameCache = nameCache
        self.notifier = notifier
        self.preferences = preferences
        self.featureFlags = featureFlags
        self.footprintMonitor = FootprintMonitor(defaults: preferences)
        self.themeChrome = ThemeChrome(palette: ChromePalette(theme: ThemePreference.activeTheme(
            isDark: NSApp?.effectiveAppearance.isDark ?? true,
            defaults: preferences
        )))
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
        // #0439: app-wide (object: nil) rather than per-window, so a single
        // observer covers every content window regardless of how many exist
        // or when they're created. `handleWindowDidBecomeKey` filters
        // non-content windows (Settings, Help, panels) via `nsWindowMap`.
        // `queue: .main` guarantees the closure runs on the main thread, but
        // NotificationCenter's `using` closure type isn't itself
        // actor-annotated, so `MainActor.assumeIsolated` bridges into this
        // main-actor-isolated instance method the same way
        // `AppearanceObserver`'s KVO callback and `AppXPCCoordinator
        // .scheduleBackoffRetry`'s `DispatchWorkItem` do for their own
        // main-thread-guaranteed, non-isolated callbacks.
        keyWindowObservation = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                self?.handleWindowDidBecomeKey(window)
            }
        }
    }

    deinit {
        if let keyWindowObservation {
            NotificationCenter.default.removeObserver(keyWindowObservation)
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
        // defaultTargetWindow() (#0439): key window first (the normal in-app
        // path), then the most recently key registered window, then the
        // newest registered one (the URL-handler path when the key window
        // hasn't been registered yet, e.g. batty <path> delivered before
        // WindowIDRegistrar fires — #0251), then windows.first in unit-test
        // contexts where no NSWindow is registered at all.
        guard let target = defaultTargetWindow() else {
            logger.error("addSession: no window available (windows empty); dropping request workingDirectory=\(workingDirectory ?? "<nil>", privacy: .public)")
            return nil
        }
        logger.debug("addSession: targeting windowID=\(target.id.value, privacy: .public) totalWindows=\(self.windows.count, privacy: .public) registeredContentWindows=\(self.nsWindowMap.count, privacy: .public) workingDirectory=\(workingDirectory ?? "<nil>", privacy: .public)")
        let result = target.addSession(title: title, workingDirectory: workingDirectory)

        // #0145: notify the active XPC watchers of a session creation.
        let event = WatchEventPayload(type: "session_created", sessionID: result.id)
        AppEventWatcher.shared.send(eventType: event.type, payload: event)

        return result
    }

    public enum ProjectOpenMode: Sendable {
        /// Select the Project's existing Session (in any Window) if one is
        /// open, otherwise open a new one.
        case focusExistingOrOpen
        /// Always open another Session, even if one is already open.
        case openNew
    }

    public struct ProjectOpenResult {
        public let session: SessionRuntime
        /// `false` when an existing Session was selected instead.
        public let wasCreated: Bool
    }

    /// Ids of Projects that currently have an open Session in any Window.
    public var openProjectIDs: Set<UUID> {
        Set(windows.flatMap(\.sessions).compactMap(\.projectID))
    }

    /// Opens a saved Project as a Session. No-op (throws `.featureDisabled`
    /// and logs) while `featureFlags.projects` is off. Startup commands are
    /// not run here.
    ///
    /// `fromCli` marks the `session_created` / `session_focused` watch events
    /// as driven by a `batty` call.
    ///
    /// `contentFactory` is a test seam forwarded to every non-terminal
    /// Pane; production callers leave it nil.
    ///
    /// The tree is built with `isSessionSelected: true` and the Session is
    /// selected in the same synchronous call, so every Pane is visible at
    /// creation.
    @discardableResult
    public func openProject(
        id projectID: UUID,
        mode: ProjectOpenMode = .focusExistingOrOpen,
        contentFactory: (@MainActor (PaneContentKind) -> (any PaneContentLifecycle)?)? = nil,
        fromCli: Bool = false
    ) throws -> ProjectOpenResult {
        guard featureFlags.projects, let projectStore else {
            logger.notice("openProject: ignored; projects feature is off")
            throw ProjectOpenError.featureDisabled
        }
        guard let project = projectStore.project(id: projectID) else {
            logger.notice("openProject: unknown project id=\(projectID, privacy: .public)")
            throw ProjectOpenError.unknownProject(projectID)
        }
        if mode == .focusExistingOrOpen,
           let window = windows.first(where: { $0.sessions.contains { $0.projectID == projectID } }),
           let existing = window.sessions.first(where: { $0.projectID == projectID }) {
            window.setSelectedSession(id: existing.id)
            activateWindow(window)
            let event = WatchEventPayload(type: "session_focused", sessionID: existing.id, fromCli: fromCli)
            AppEventWatcher.shared.send(eventType: event.type, payload: event)
            return ProjectOpenResult(session: existing, wasCreated: false)
        }
        guard let target = defaultTargetWindow() else {
            logger.error("openProject: no window available")
            throw ProjectOpenError.noWindow
        }
        let tree = try ProjectTreeBuilder.build(
            project: project,
            contentFactory: contentFactory,
            isSessionSelected: true
        )
        let session = target.addProjectSession(project, tree: tree)
        // A CLI create brings Batty forward like `batty new` does (its
        // `open -a` activates the app); GUI opens are already in front.
        if fromCli { activateWindow(target) }
        let event = WatchEventPayload(type: "session_created", sessionID: session.id, fromCli: fromCli)
        AppEventWatcher.shared.send(eventType: event.type, payload: event)
        return ProjectOpenResult(session: session, wasCreated: true)
    }

    /// `fromCli` forwards to `WindowRuntime.removeSession(id:fromCli:)`,
    /// which is now the sole `session_destroyed` emitter (#0396) — this
    /// wrapper no longer emits its own copy, so a stale/unknown `id` (for
    /// which `windowOwning` finds nothing) emits nothing, fixing the
    /// phantom-event-before-validation defect the old duplicate emission
    /// here had.
    public func removeSession(id: UUID, fromCli: Bool = false) {
        cancelNameSuggestion(forSessionID: id)

        // Locate the owning window by session ID — the session may be in any window.
        windowOwning(sessionID: id)?.removeSession(id: id, fromCli: fromCli)
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

    /// Creates a Tab in the Pane `id` and moves Pane focus there, so the new
    /// Tab is typeable even when another Pane was focused. Both writes happen
    /// in the caller's event handler, so the Pane is already focused when the
    /// new Tab mounts and `PaneView`'s `.onAppear` trigger focuses it. Call
    /// only from user-event handlers (see docs/swiftui-observation-rules.md).
    /// Returns `nil` for an unknown Pane.
    @discardableResult
    public func addTab(toPaneID id: UUID, inheritingCWDFrom source: TabRuntime? = nil) -> TabRuntime? {
        guard let (window, pane) = locatePane(id: id) else { return nil }
        window.focusPane(id: id)
        return pane.addTab(inheritingCWDFrom: source)
    }

    private func locatePane(id: UUID) -> (WindowRuntime, PaneRuntime)? {
        for window in windows {
            for session in window.sessions {
                if let pane = session.tree.allPanes.first(where: { $0.id == id }) {
                    return (window, pane)
                }
            }
        }
        return nil
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

    // MARK: - XPC pane hide/show (#0382)

    /// Outcome of `hidePaneForXPC(id:)` — the app-side source of the XPC
    /// `pane hide` verb.
    public enum PaneHideOutcome: Equatable, Sendable {
        /// The pane was visible and is now hidden.
        case hidden
        /// The pane was already hidden — `pane hide` on a hidden pane
        /// succeeds quietly (idempotent), matching `pane show`'s own
        /// already-visible case.
        case alreadyHidden
        /// No pane with that id exists in any window — the
        /// stale/unknown-id case `AppXPCService` turns into a failure
        /// reply (CLI exit `4`).
        case unknownPane
        /// The pane is its session's only visible pane. `hidePane(id:)`
        /// already enforces the ≥1-visible-pane invariant (#0256) as a
        /// silent no-op (Void return, nothing for a caller to read); over
        /// XPC that would read as a false success (exit `0` for a hide
        /// that never happened), so this makes the refusal a visible
        /// failure instead — the same "visible failure over silent no-op"
        /// shape `PaneCloseOutcome.refusedLastPane` already established
        /// one tier up, applied to this pane-hide-specific invariant.
        case refusedLastVisiblePane
    }

    /// `pane hide` (#0382): hides `paneID`, reusing `hidePane(id:)` (the
    /// same entry point the sidebar's eye toggle uses) for the actual
    /// mutation — this method only classifies the outcome, it never
    /// duplicates `hidePane`'s hide/focus-move logic. Searches every
    /// window's every session, same as `closePane`/`splitPane`, so a
    /// background-session target resolves identically to a foreground one
    /// (#0257); never touches `selectedSessionID`.
    @discardableResult
    public func hidePaneForXPC(id paneID: UUID) -> PaneHideOutcome {
        for window in windows {
            guard let session = window.sessions.first(where: { $0.tree.allPanes.contains(where: { $0.id == paneID }) }),
                  let pane = session.tree.allPanes.first(where: { $0.id == paneID })
            else { continue }
            if pane.isHidden { return .alreadyHidden }
            guard session.tree.visiblePanes.count > 1 else {
                logger.notice("hidePaneForXPC: refused pane=\(paneID, privacy: .public) reason=last-visible-pane")
                return .refusedLastVisiblePane
            }
            window.hidePane(id: paneID)
            return .hidden
        }
        return .unknownPane
    }

    /// Outcome of `showPaneForXPC(id:)` — the app-side source of the XPC
    /// `pane show` verb.
    public enum PaneShowOutcome: Equatable, Sendable {
        /// The pane was hidden and is now visible.
        case shown
        /// The pane was already visible — `pane show` on a visible pane
        /// succeeds quietly (idempotent).
        case alreadyVisible
        /// No pane with that id exists in any window — the
        /// stale/unknown-id case `AppXPCService` turns into a failure
        /// reply (CLI exit `4`). The only failure mode: unlike `pane
        /// hide`, showing a pane never violates the ≥1-visible-pane
        /// invariant.
        case unknownPane
    }

    /// `pane show <pane-id>` (#0382): un-hides `paneID`, reusing
    /// `showPane(id:)` for the actual mutation. **No fallback target** —
    /// the CLI never resolves `BATTY_PANE_ID`/the focused pane for this
    /// verb (#0257: a hidden pane has no shell to run `batty` from), so
    /// `paneID` always names an explicit id by the time it reaches here.
    @discardableResult
    public func showPaneForXPC(id paneID: UUID) -> PaneShowOutcome {
        for window in windows {
            guard let session = window.sessions.first(where: { $0.tree.allPanes.contains(where: { $0.id == paneID }) }),
                  let pane = session.tree.allPanes.first(where: { $0.id == paneID })
            else { continue }
            if !pane.isHidden { return .alreadyVisible }
            window.showPane(id: paneID)
            return .shown
        }
        return .unknownPane
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

    // MARK: - XPC focus verbs (#0381)

    /// Outcome of `focusSessionForXPC(id:)` — the app-side source of the
    /// XPC `session focus` verb.
    public enum SessionFocusOutcome: Equatable, Sendable {
        case focused
        /// No session with that id exists in any window — the
        /// stale/unknown-id case `AppXPCService` turns into a failure
        /// reply (CLI exit `4`).
        case unknownSession
    }

    /// `session focus <id>` (#0381): selects the target session and
    /// activates its window — #0257's 2026-07-27 terminology amendment
    /// names the `focus` verbs as the CLI's one sanctioned exception to
    /// "a mutation aimed at a background session must not switch the
    /// active session." Unlike `pane focus`/`tab focus`, there is no pane
    /// or tab to touch — this only ever changes `selectedSessionID` and
    /// brings the window forward. Reuses `windowOwning(sessionID:)` (the
    /// same lookup `renameSession`/`removeSession`/`duplicateSession` use)
    /// and `WindowRuntime.setSelectedSession(id:)` (the sidebar's own
    /// selection entry point).
    @discardableResult
    public func focusSessionForXPC(id sessionID: UUID) -> SessionFocusOutcome {
        guard let window = windowOwning(sessionID: sessionID) else { return .unknownSession }
        window.setSelectedSession(id: sessionID)
        activateWindow(window)
        let event = WatchEventPayload(type: "session_focused", sessionID: sessionID, fromCli: true)
        AppEventWatcher.shared.send(eventType: event.type, payload: event)
        return .focused
    }

    /// Outcome of `focusPaneForXPC(id:)` — the app-side source of the XPC
    /// `pane focus` verb. Only one failure mode exists (unlike
    /// `PaneCloseOutcome`'s three cases), so this mirrors `NotifyOutcome`'s
    /// two-case shape.
    public enum PaneFocusOutcome: Equatable, Sendable {
        case focused
        /// No pane with that id exists in any window — the stale/unknown-id
        /// case `AppXPCService` turns into a failure reply (CLI exit `4`).
        case unknownPane
    }

    /// Outcome of `focusTabForXPC(id:)` — the app-side source of the XPC
    /// `tab focus` verb.
    public enum TabFocusOutcome: Equatable, Sendable {
        case focused
        /// No tab with that id exists in any window — the stale/unknown-id
        /// case `AppXPCService` turns into a failure reply (CLI exit `4`).
        case unknownTab
    }

    /// `pane focus <id>` (#0381): selects the pane's owning session and
    /// activates its window — #0257's 2026-07-27 terminology amendment
    /// names the `focus` verbs as the CLI's one sanctioned exception to
    /// "a mutation aimed at a background session must not switch the
    /// active session" — but leaves the pane's `activeTabID` untouched:
    /// moving focus between panes must never re-select tabs.
    ///
    /// Reuses `WindowRuntime.setSelectedSession(id:)` (the sidebar's own
    /// selection entry point, not a direct `selectedSessionID` write) and
    /// `WindowRuntime.focusPane(id:)` (already idempotent — an equal-value
    /// write is skipped rather than re-notifying every `PaneView`), and the
    /// same pane-owner search shape `splitPane`/`closePane`/`hidePane`/
    /// `showPane` above already use.
    @discardableResult
    public func focusPaneForXPC(id paneID: UUID) -> PaneFocusOutcome {
        for window in windows {
            guard let session = window.sessions.first(where: { $0.tree.allPanes.contains(where: { $0.id == paneID }) }) else { continue }
            window.setSelectedSession(id: session.id)
            // #0256's invariant ("focus must never land on a hidden pane")
            // holds for this verb too — un-hide before the focus write
            // below, same as `jumpToBellEntry`'s un-hide-before-navigating
            // rule, though the session-selection write above happens
            // first here rather than after (not observable: both are
            // synchronous main-actor writes with no reconciliation
            // between them).
            if let pane = session.tree.allPanes.first(where: { $0.id == paneID }), pane.isHidden {
                window.showPane(id: paneID)
            }
            window.focusPane(id: paneID)
            activateWindow(window)
            let event = WatchEventPayload(type: "pane_focused", sessionID: session.id, targetPaneID: paneID, fromCli: true)
            AppEventWatcher.shared.send(eventType: event.type, payload: event)
            return .focused
        }
        return .unknownPane
    }

    /// `tab focus <id>` (#0381): selects the tab if it isn't already its
    /// pane's active tab, and implies focusing that pane — the tab-level
    /// counterpart of `focusPaneForXPC(id:)`, one tier further down, both
    /// activating per the same terminology amendment. Mirrors
    /// `WindowRuntime.jumpToTab`'s session/pane/tab write order (select
    /// session, focus pane, set `activeTabID`) and, per #0145, also emits
    /// `active_tab_changed` when the write actually flips the active tab —
    /// `jumpToTab` emits it (`WindowRuntime.swift`), and a `batty watch`
    /// subscriber relying on that event to track the active tab must not
    /// silently miss a change driven by `tab focus`. Reuses
    /// `WindowRuntime.locate(tabID:)` rather than re-walking the tree.
    @discardableResult
    public func focusTabForXPC(id tabID: UUID) -> TabFocusOutcome {
        for window in windows {
            guard let location = window.locate(tabID: tabID) else { continue }
            window.setSelectedSession(id: location.session.id)
            // Same #0256 invariant as `focusPaneForXPC`: un-hide the
            // containing pane before the focus write, since `tab focus`
            // implies focusing its pane.
            if location.pane.isHidden {
                window.showPane(id: location.pane.id)
            }
            window.focusPane(id: location.pane.id)
            let oldTabID = location.pane.activeTabID
            if oldTabID != tabID {
                let oldTabTitle = location.pane.tabs.first(where: { $0.id == oldTabID })?.titleOverride ?? ""
                location.pane.activeTabID = tabID
                let newTabTitle = location.pane.tabs.first(where: { $0.id == tabID })?.titleOverride ?? ""
                let activeTabChangedEvent = WatchEventPayload(
                    type: "active_tab_changed",
                    sessionID: location.session.id,
                    targetPaneID: location.pane.id,
                    oldTabTitle: oldTabTitle,
                    newTabTitle: newTabTitle,
                    fromCli: true
                )
                AppEventWatcher.shared.send(eventType: activeTabChangedEvent.type, payload: activeTabChangedEvent)
            }
            activateWindow(window)
            let event = WatchEventPayload(type: "tab_focused", sessionID: location.session.id, targetPaneID: location.pane.id, tabID: tabID, fromCli: true)
            AppEventWatcher.shared.send(eventType: event.type, payload: event)
            return .focused
        }
        return .unknownTab
    }

    /// Makes `window`'s `NSWindow` key and front and brings the app itself
    /// forward — the cross-window bring-forward half of the focus verbs'
    /// activation. The XPC focus verbs are always the out-of-app case (an
    /// agent runs `batty` from a shell while the human is in another app or
    /// Space), unlike `jumpToBellEntry`'s in-app feed-click path, where
    /// Batty is already frontmost and `makeKeyAndOrderFront` alone
    /// suffices. The correct precedent is `BellNotifier`'s
    /// notification-tap path, which pairs the jump with
    /// `NSApp.activate(ignoringOtherApps:)` for exactly this reason.
    /// Also deminiaturizes first — `makeKeyAndOrderFront` does not restore
    /// a minimized window, so `pane focus` into one would otherwise be a
    /// silent visual no-op. A responder/app-activation-changing AppKit
    /// call: legal here for the same reason it's legal in
    /// `jumpToBellEntry`/`BellNotifier` — every caller is event-origin: the
    /// XPC-dispatched `Task { @MainActor }` in `AppXPCService.perform`, the
    /// trust sheet's button via `resolveStartupTrust`, and `openProject`'s
    /// focus-existing branch, reached from GUI project opens (Command
    /// Palette, project editor) via `ProjectOpenPresenter` and from
    /// `UITestDriver` — never from view-update code. No-op when the window has no
    /// registered `NSWindow` yet (unit tests, headless CLI-only contexts)
    /// — the selection/focus writes above already ran regardless, which is
    /// what the store-state assertions in tests exercise.
    func activateWindow(_ window: WindowRuntime) {
        windowActivationObserver?(window)
        guard let nsWindow = nsWindow(for: window.id) else { return }
        if nsWindow.isMiniaturized {
            nsWindow.deminiaturize(nil)
        }
        nsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

    // MARK: - pwd delegate wiring (#0436)

    /// Installs the pwd delegate callback for `tab`: libghostty's
    /// authoritative pwd report drives session and tab auto-naming through
    /// ``applyReportedWorkingDirectory(_:to:)``. Call once per tab from a
    /// `.task`, matching every other `tab.terminalDelegate` wiring in
    /// `PaneView` — not from `body`/`onChange`/`onAppear` (installing a
    /// closure is not itself an observed-state write, but keeping the
    /// wiring out of view-driven code avoids any question of it becoming
    /// one later; see `docs/swiftui-observation-rules.md`).
    ///
    /// Living in `AppStateStore` rather than as a closure literal in
    /// `PaneView` means the production callback path is exercised by
    /// calling this method directly from a unit test, through the real
    /// `TerminalDelegateProxy`/`TerminalViewState` — round-1 review found
    /// that a closure duplicated ad hoc in a test could silently diverge
    /// from what `PaneView` actually installs (e.g. keep the stale
    /// `terminal.workingDirectory` re-read `PaneView` no longer performs)
    /// without any test catching it.
    public func wireWorkingDirectoryReporting(for tab: TabRuntime) {
        tab.terminalDelegate.onWorkingDirectoryChange = { [weak self, weak tab] path in
            guard let self, let tab else { return }
            self.applyReportedWorkingDirectory(path, to: tab)
        }
    }

    /// The pwd delegate callback's single entry point. `path` is
    /// non-optional by design: the round-1 review found that an
    /// optional-with-`nil`-default `reportedPath` parameter on the naming
    /// methods let a caller silently reintroduce the stale read this issue
    /// fixes (passing `nil`, or a call site that dropped the argument,
    /// compiled and passed every existing test). Making the reported path
    /// required here means that mistake fails to compile instead.
    public func applyReportedWorkingDirectory(_ path: String, to tab: TabRuntime) {
        tab.applyReportedWorkingDirectory(path)
        applySessionAutoNaming(forTabID: tab.id, cwdOverride: path)
        applyTabAutoNaming(for: tab, cwdOverride: path)
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
    ///
    /// On-demand path only: resolves the cwd from the live
    /// `terminal.workingDirectory`/`configuration.workingDirectory`. Do
    /// **not** call this from the pwd delegate callback — at that point
    /// `terminal.workingDirectory` is still the *previous* directory,
    /// because `TerminalViewState`'s write is deferred to the next
    /// main-queue turn (`publishSoon`, libghostty-spm). The callback path
    /// goes through ``applyReportedWorkingDirectory(_:to:)`` instead, which
    /// takes the reported path directly (#0436).
    public func handleWorkingDirectoryChange(forTabID tabID: UUID) {
        applySessionAutoNaming(forTabID: tabID, cwdOverride: nil)
    }

    /// Shared core of ``handleWorkingDirectoryChange(forTabID:)`` and
    /// ``applyReportedWorkingDirectory(_:to:)``. `cwdOverride`, when given,
    /// is used as-is instead of re-reading `terminal.workingDirectory`;
    /// `nil` falls back to the live property for the on-demand callers.
    /// Kept `private` and defaulted only internally — the public surface
    /// has no optional-path entry point a caller could silently pass `nil`
    /// to and reintroduce the stale read (round-1 review finding).
    private func applySessionAutoNaming(forTabID tabID: UUID, cwdOverride: String?) {
        // Search across ALL windows — the `sessions` shim resolves to
        // windows[0] only, so using it here would silently skip sessions in
        // every other window (#0248 trigger bug).
        for window in windows {
            for (index, session) in window.sessions.enumerated() {
                let anchorTab = session.tree.root.firstLeafPane.tabs[0]
                guard anchorTab.id == tabID else { continue }
                guard !session.titleOverride else { return }
                guard session.tree.allPanes.count == 1 else { return }
                let cwd = cwdOverride
                    ?? anchorTab.terminal.workingDirectory
                    ?? anchorTab.terminal.configuration.workingDirectory
                guard let cwd, !cwd.isEmpty else { return }
                var resolved = Self.resolveAutoTitle(
                    forCWD: cwd,
                    sessionIndex: index,
                    cache: nameCache,
                    resolver: ProjectNameResolver.shared,
                    nameFromFiles: SettingsPreference.resolvedAutoNameFromFiles(defaults: preferences)
                )
                if Self.isDefaultSessionTitle(resolved) {
                    // Deterministic chain missed — AI fallback (#0231). A
                    // memoized suggestion stands in for the default directly;
                    // an unknown path kicks off an async request. The settings
                    // toggle (#0233) gates the whole AI step, memo included —
                    // a memoized AI name is still automatic naming.
                    if !SettingsPreference.resolvedAutoNameWithAI(defaults: preferences) {
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
    ///
    /// On-demand path only: resolves the cwd from the live
    /// `terminal.workingDirectory`/`configuration.workingDirectory`. Do
    /// **not** call this from the pwd delegate callback — see
    /// ``handleWorkingDirectoryChange(forTabID:)``'s doc comment for why;
    /// the callback path goes through
    /// ``applyReportedWorkingDirectory(_:to:)`` instead (#0436).
    public func updateTabAutoName(for tab: TabRuntime) {
        applyTabAutoNaming(for: tab, cwdOverride: nil)
    }

    /// Shared core of ``updateTabAutoName(for:)`` and
    /// ``applyReportedWorkingDirectory(_:to:)``. See
    /// ``applySessionAutoNaming(forTabID:cwdOverride:)`` for why this stays
    /// `private` with an internally-defaulted override rather than exposing
    /// an optional-path parameter publicly.
    private func applyTabAutoNaming(for tab: TabRuntime, cwdOverride: String?) {
        guard tab.titleOverride == nil else {
            cancelTabNameSuggestion(forTabID: tab.id)
            return
        }
        guard SettingsPreference.resolvedAutoNameWithAI(defaults: preferences) else {
            cancelTabNameSuggestion(forTabID: tab.id)
            return
        }
        let cwd = cwdOverride ?? tab.terminal.workingDirectory ?? tab.terminal.configuration.workingDirectory
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

    /// Resolves a `SessionRuntime` by id across all windows. Used to route
    /// a tab-scoped event (e.g. a clipboard-read confirmation) up to its
    /// owning Session, whose id is already known once `TabRuntime.attachContext(paneID:sessionID:)`
    /// has run (#0281).
    public func session(id sessionID: UUID) -> SessionRuntime? {
        windows.flatMap(\.sessions).first { $0.id == sessionID }
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
        let systemNotificationsEnabled = SettingsPreference.resolvedSystemNotifications(defaults: preferences)
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
    ///
    /// The scheduled `Task` is kept in `summarizationTasksForTesting`, keyed
    /// by entry id, purely so tests can await the real completion signal
    /// (`docs/async-test-seams.md` §4, "returned/exposed Task") instead of
    /// polling with `Task.yield()`. A summarizer that's nil or a toggle
    /// that's off means no `Task` is ever created, which is exactly the
    /// "skipped" signal those tests need — nothing to await, not a
    /// fabricated empty wait.
    ///
    /// Entries are pruned here, before adding the new one, for every id no
    /// longer present in `bellFeed.entries` — `BellFeedStore` already caps
    /// how many entries it retains, so this bounds the dictionary the same
    /// way instead of growing it for the life of the app. This is
    /// deliberately not a `defer` inside the `Task` itself: a summarizer
    /// with no real `await` inside it can let the `Task` run to completion
    /// (and remove its own entry) before the caller that just scheduled it
    /// gets a chance to look the entry up, which would make "was one
    /// scheduled" indistinguishable from "already finished". Pruning by
    /// feed membership instead can never remove the entry this call is
    /// about to add — it was just recorded into `bellFeed` by the caller.
    private func scheduleSummarization(for entry: BellFeedEntry, tabTitle: String, sessionTitle: String) {
        guard let summarizer = notificationSummarizer else { return }
        guard SettingsPreference.resolvedSummarizeNotificationsWithAI(defaults: preferences) else { return }
        let entryID = entry.id
        let message = entry.message
        let tabTitleCopy = tabTitle
        let sessionTitleCopy = sessionTitle
        let task = Task { [weak self] in
            let raw = await summarizer.summarize(
                message: message,
                tabTitle: tabTitleCopy.isEmpty ? nil : tabTitleCopy,
                sessionTitle: sessionTitleCopy.isEmpty ? nil : sessionTitleCopy
            )
            guard let self, !Task.isCancelled else { return }
            guard let summary = raw.flatMap(NotificationSummary.sanitize) else { return }
            self.bellFeed.updateSummary(summary, forEntryID: entryID)
        }
        let liveIDs = Set(bellFeed.entries.map(\.id))
        summarizationTasksForTesting = summarizationTasksForTesting.filter { liveIDs.contains($0.key) }
        summarizationTasksForTesting[entryID] = task
    }

    /// Test-only. The summarization `Task` `scheduleSummarization` started
    /// for `entryID`, if it started one at all. `nil` means a nil summarizer
    /// or a disabled toggle made `scheduleSummarization` return before ever
    /// creating a `Task` — a synchronous "was this skipped" answer, not "not
    /// found yet". A plain read accessor rather than an awaited helper: the
    /// bounded await belongs in the test target, on the shared `ResumeOnce`
    /// (`BattyKit/Tests/BattyKitTests/ResumeOnce.swift`), not duplicated here
    /// in production source.
    func summarizationTaskForTesting(entryID: UUID) -> Task<Void, Never>? {
        summarizationTasksForTesting[entryID]
    }
}
