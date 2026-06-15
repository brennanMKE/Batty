// AppStateStore.swift

import Foundation
import Observation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "AppStateStore")

@Observable
public final class AppStateStore {
    public static let shared = AppStateStore()

    // MARK: - Global services (cross-window)

    public let bellFeed: BellFeedStore
    public let nameCache: SessionNameCache
    public let themeChrome: ThemeChrome
    @ObservationIgnored public var notifier: BellNotifying?
    /// Called when `removeSession` empties the window's `sessions`. Nil in
    /// unit tests; the app delegate sets this to terminate the process.
    /// Forwarded to `windows[0].onAllSessionsClosed`.
    @ObservationIgnored public var onAllSessionsClosed: (() -> Void)? {
        get { windows[0].onAllSessionsClosed }
        set { windows[0].onAllSessionsClosed = newValue }
    }
    /// AI fallback for session auto-naming (#0231). Nil disables the AI
    /// step entirely — the deterministic chain behaves exactly as before.
    /// The app delegate wires `FoundationModelsNameSuggester.makeIfAvailable()`.
    @ObservationIgnored public var nameSuggester: SessionNameSuggesting?
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

    // MARK: - Per-window state

    /// All content windows. One element in the current (phase 2) single-window
    /// era; grows in `#0237` when `New Window` is added.
    @ObservationIgnored public private(set) var windows: [WindowRuntime]

    /// Returns the `WindowRuntime` whose `id` matches, or `nil` if not found.
    public func windowRuntime(for windowID: WindowID) -> WindowRuntime? {
        windows.first { $0.id == windowID }
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
        self.windows = [window]
    }

    // MARK: - Per-window forwarding shims (resolve to windows[0])
    //
    // Every property and method below is a thin forwarder to the single
    // WindowRuntime. All existing call sites — app code, views, shortcuts,
    // tests — continue to resolve through AppStateStore unchanged. When
    // #0237 adds multiple windows, callers that need to target a specific
    // window will switch to windowRuntime(for:) directly.

    public var sessions: [SessionRuntime] {
        windows[0].sessions
    }

    public var selectedSessionID: UUID? {
        get { windows[0].selectedSessionID }
        set { windows[0].selectedSessionID = newValue }
    }

    public var selectedSession: SessionRuntime? {
        windows[0].selectedSession
    }

    public var pendingCloseRequest: PendingCloseRequest? {
        get { windows[0].pendingCloseRequest }
        set { windows[0].pendingCloseRequest = newValue }
    }

    @discardableResult
    public func addSession(title: String? = nil) -> SessionRuntime {
        windows[0].addSession(title: title)
    }

    public func removeSession(id: UUID) {
        cancelNameSuggestion(forSessionID: id)
        windows[0].removeSession(id: id)
    }

    public func renameSession(id: UUID, to newTitle: String) {
        windows[0].renameSession(id: id, to: newTitle)
        // Cancel any in-flight AI naming — an explicit user rename pins
        // the title and must not be overwritten by a late suggestion.
        cancelNameSuggestion(forSessionID: id)
    }

    public func clearSessionName(id: UUID) {
        windows[0].clearSessionName(id: id)
    }

    @discardableResult
    public func duplicateSession(id: UUID) -> SessionRuntime? {
        windows[0].duplicateSession(id: id)
    }

    public func moveSessions(fromOffsets source: IndexSet, toOffset destination: Int) {
        windows[0].moveSessions(fromOffsets: source, toOffset: destination)
    }

    public func selectSession(at index: Int) {
        windows[0].selectSession(at: index)
    }

    public func closeTab(id tabID: UUID) {
        windows[0].closeTab(id: tabID)
    }

    public func closeFocusedTab() {
        windows[0].closeFocusedTab()
    }

    public func requestCloseTab(id tabID: UUID) {
        windows[0].requestCloseTab(id: tabID)
    }

    public func requestCloseFocusedTab() {
        windows[0].requestCloseFocusedTab()
    }

    public func requestCloseOtherTabs(paneID: UUID, keepingTabID: UUID) {
        windows[0].requestCloseOtherTabs(paneID: paneID, keepingTabID: keepingTabID)
    }

    public func confirmPendingClose() {
        windows[0].confirmPendingClose()
    }

    public func cancelPendingClose() {
        windows[0].cancelPendingClose()
    }

    public func focusPane(id: UUID) {
        windows[0].focusPane(id: id)
    }

    public func focusPane(containingTabID tabID: UUID) {
        windows[0].focusPane(containingTabID: tabID)
    }

    public func jumpToTab(sessionID: UUID, tabID: UUID) {
        windows[0].jumpToTab(sessionID: sessionID, tabID: tabID)
    }

    public func markActiveTabSeen() {
        windows[0].markActiveTabSeen()
    }

    // MARK: - Bell event routing (global — searches across all windows)

    public func recordBellTick(forTabID tabID: UUID, surfaceID: UUID = UUID(), windowID: UUID = UUID()) {
        for window in windows {
            guard let location = window.locate(tabID: tabID) else { continue }
            let delta = location.tab.recordBellTickIfNeeded()
            guard delta > 0 else { return }
            for _ in 0..<delta {
                let entry = BellFeedEntry(
                    timestamp: location.tab.lastBellAt ?? Date(),
                    windowID: windowID,
                    sessionID: location.session.id,
                    paneID: location.pane.id,
                    tabID: location.tab.id,
                    surfaceID: surfaceID,
                    message: nil,
                    seen: location.isFocused
                )
                bellFeed.record(entry)
                window.propagateUnseen(at: location)
                postNotification(for: entry, at: location)
            }
            return
        }
    }

    public func recordDesktopNotification(forTabID tabID: UUID, surfaceID: UUID = UUID(), windowID: UUID = UUID()) {
        for window in windows {
            guard let location = window.locate(tabID: tabID) else { continue }
            guard location.tab.recordDesktopNotificationIfNeeded() else { return }
            let entry = BellFeedEntry(
                timestamp: location.tab.lastBellAt ?? Date(),
                windowID: windowID,
                sessionID: location.session.id,
                paneID: location.pane.id,
                tabID: location.tab.id,
                surfaceID: surfaceID,
                message: location.tab.lastBellMessage,
                seen: location.isFocused
            )
            bellFeed.record(entry)
            window.propagateUnseen(at: location)
            postNotification(for: entry, at: location)
            return
        }
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

    public func jumpToBellEntry(_ entry: BellFeedEntry) {
        for window in windows {
            window.jumpToBellEntry(entry)
        }
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
        for (index, session) in sessions.enumerated() {
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
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
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

    // MARK: - Private helpers

    private func postNotification(for entry: BellFeedEntry, at location: WindowRuntime.BellLocation) {
        guard let notifier else { return }
        guard !location.session.notificationsMuted else { return }
        let paneIndex = (location.session.tree.allPanes.firstIndex { $0.id == location.pane.id } ?? 0) + 1
        let tabIndex = (location.pane.tabs.firstIndex { $0.id == location.tab.id } ?? 0) + 1
        let tabLabel: String
        if let override = location.tab.titleOverride, !override.isEmpty {
            tabLabel = override
        } else if !location.tab.terminal.title.isEmpty {
            tabLabel = location.tab.terminal.title
        } else {
            tabLabel = String(localized: "Tab \(tabIndex)")
        }
        notifier.post(
            for: entry,
            sessionTitle: location.session.title,
            paneIndex: paneIndex,
            tabLabel: tabLabel
        )
    }
}
