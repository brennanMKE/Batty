// TabRuntime.swift

import AppKit
import Foundation
import GhosttyTerminal
import Observation

@Observable
public final class TabRuntime: Identifiable {
    public let id: UUID
    public var titleOverride: String?
    public let terminal: TerminalViewState

    public internal(set) var bellCount: Int = 0
    public internal(set) var unseenBellCount: Int = 0
    public internal(set) var lastBellAt: Date?
    public internal(set) var lastBellMessage: String?

    public internal(set) var runningCommandDisplayName: String?

    /// Non-nil while an approved Project startup command is armed but its
    /// shell never reported readiness. Mirrors ``TerminalDelegateProxy``'s
    /// state so views can observe it.
    public internal(set) var startupCommandWaiting: StartupCommandWaiting?

    /// The owning pane/session, filled in by ``attachContext(paneID:sessionID:)``
    /// once this tab is placed into a `PaneRuntime` that has joined a
    /// `SessionRuntime`. `nil` at construction — see that method's doc for
    /// why the ids aren't knowable in `init`.
    public internal(set) var paneID: UUID?
    public internal(set) var sessionID: UUID?

    /// Per-tab command override (#0282's `pane split -c`) — replaces the
    /// global shell preference for this tab only, so an agent can open a
    /// pane running an explicit command rather than the default shell.
    /// Immutable: set once at construction and re-applied unchanged by
    /// ``attachContext(paneID:sessionID:)``'s config re-apply.
    private let commandOverride: String?

    /// Source of the app-wide background, read again on each config render.
    /// See ``applyShellAndAppearancePreferences(to:tabID:paneID:sessionID:command:background:appearance:)``
    /// for why the other preferences don't come from here.
    @ObservationIgnored
    private let backgroundGate: AppWideBackgroundGate

    /// The owning Pane's override and its Session's, which `PaneRuntime` keeps
    /// current. Stored here because every config render replaces the whole
    /// override set.
    @ObservationIgnored
    private(set) var paneBackgroundOverride: TerminalBackgroundSettings?
    @ObservationIgnored
    private(set) var sessionBackgroundOverride: TerminalBackgroundSettings?

    /// This Tab's own background, the narrowest level of the chain. `nil`
    /// follows the Pane. Observed because see-through and the chip menu read it.
    public private(set) var backgroundOverride: TerminalBackgroundSettings?

    /// The image this Tab opened without because it was missing or hadn't
    /// reached this Mac. While set, Update Project keeps this identity and an
    /// arriving image is applied. Any write to this Tab's own value clears it.
    @ObservationIgnored
    var pendingTabImage: ProjectTabImage?

    /// The startup command the Project opened this Tab with, so Update Project
    /// keeps it on this Tab wherever it moves. New, duplicated and split Tabs
    /// have none.
    @ObservationIgnored
    public internal(set) var projectStartupCommand: String?

    /// Observation-tracked mirror of `terminal.workingDirectory`. That
    /// property is Combine `@Published` on an `ObservableObject`
    /// (`TerminalViewState`, from the GhosttyTerminal package), which the
    /// `@Observable` view layer does not track — reading it from `body`
    /// left tab chips and the sidebar pane row stuck on the tab's initial
    /// directory after `cd` (#0260, following the session-title staleness
    /// fixed the same way in #0227). View-reachable code (``TabTitleFormatter``)
    /// must read this mirror, never `terminal.workingDirectory` directly;
    /// non-view event-handler code (``AppStateStore``) may still read the
    /// live Combine value on its own on-demand call paths (a rename commit,
    /// a new split/tab inheriting cwd, the initial resolve) — but **not**
    /// synchronously inside the pwd delegate callback itself, where the
    /// live property is still the *previous* directory because
    /// `TerminalViewState`'s write is deferred to the next main-queue turn
    /// (`publishSoon`, libghostty-spm). That callback goes through
    /// ``applyReportedWorkingDirectory(_:)`` instead (#0436).
    /// Written via ``applyReportedWorkingDirectory(_:)`` (the pwd delegate
    /// callback, with the reported path) and
    /// ``syncWorkingDirectoryFromTerminal()`` (the on-demand path, reading
    /// the live property) — both event-origin, not view-update code.
    public internal(set) var workingDirectory: String?

    /// Observation-tracked mirror of `terminal.title` (the #0260 pattern).
    /// View-reachable code and code running inside a delegate callback
    /// (bell intake) read this, never `terminal.title`, which is
    /// Combine-backed and published a main-queue turn late. Written only by
    /// ``receiveTitleChange(_:)`` with the reported value. Starts at `""`,
    /// matching a fresh `TerminalViewState`'s title.
    public internal(set) var terminalTitle: String = ""

    /// Per-cwd name suggested by the on-device model (mirrors the session
    /// auto-naming mechanism — see `AppStateStore.updateTabAutoName(for:)`).
    /// `nil` means "no AI name for the current directory": suggestion
    /// disabled, model unavailable, no signal, or not yet resolved.
    /// ``TabTitleFormatter`` only consults this after every more specific
    /// signal (override, live title, running command) has come up empty.
    public internal(set) var aiSuggestedName: String?

    /// Set by ``TerminalHostView`` while a Finder drag is hovering over
    /// this tab's terminal subview; cleared on drag exit or drop. Drives
    /// the accent-color overlay in ``PaneView``. Lives on the model
    /// because the AppKit host (which receives the drag callbacks) and
    /// the SwiftUI overlay are siblings under different parents — a model
    /// flag is the smallest path between them.
    public internal(set) var isDragHovering: Bool = false

    /// Long-lived libghostty NSView whose lifetime is bound to this tab,
    /// not to any SwiftUI representable. The view is owned by
    /// ``TerminalHostStore`` (which adds it as a subview of the persistent
    /// per-window ``TerminalHostView`` on first appearance and nils this
    /// property out — as well as removing the subview and forcing the
    /// surface free — in ``TerminalHostStore/releaseTerminalView(forTabID:)``
    /// on tab close); this property is the canonical back-reference for
    /// tests and any tab-scoped consumer that needs the view directly.
    /// Treat it as read-mostly — the host store is the authority.
    ///
    /// Nil'd at close time (#0289), but note what that nil-out does and
    /// doesn't do: `releaseTerminalView` frees the terminal surface and
    /// PTY *before* this property is cleared, by setting the view's own
    /// `controller` to `nil` — a real, synchronous
    /// `ghostty_surface_free`, not something contingent on this
    /// back-reference or on anything about `TabRuntime`'s lifetime. So
    /// nil-ing this property is reference hygiene (no stale reads of a
    /// torn-down view through a `TabRuntime` a SwiftUI view is still
    /// holding), not what keeps the surface from leaking. The ghostty
    /// app (`ghostty_app_t`, owned by `terminal.controller`) is the
    /// separate matter this property was never going to cover either
    /// way: it's freed only when `TabRuntime` itself deallocates,
    /// because `terminal.controller` is `TabRuntime`'s own independent
    /// strong reference to the same `TerminalController` — untouched by
    /// anything that happens to this property or to the view.
    @ObservationIgnored
    public internal(set) var terminalNSView: AppTerminalView?

    @ObservationIgnored
    let terminalDelegate: TerminalDelegateProxy

    /// Where rung bells go once a store is wired. Until then they are held
    /// in ``pendingBells``/``pendingNotification`` (bounded: a count and the
    /// latest notification) and flushed by ``setBellIntake(_:)``.
    @ObservationIgnored
    private var bellIntake: ((TabRuntime, BellIntakeEvent) -> Void)?
    @ObservationIgnored
    private var pendingBells: (count: Int, lastAt: Date)?
    @ObservationIgnored
    private var pendingNotification: (message: String?, at: Date)?

    /// Testability hook only (`internal`, reached via `@testable import` in
    /// `BattyKitTests`) — lets a test force this Tab's ``needsConfirmClose``
    /// to `true` without a live libghostty surface (#0398). `nil` (every
    /// production `TabRuntime`, which never sets this) falls through to the
    /// real `terminal.needsConfirmClose`, so production behavior is
    /// unchanged: that predicate is itself hard-coded `false` by
    /// `TerminalViewState+Polyfill.swift` until upstream `libghostty-spm`
    /// exposes the real signal. Setting this is the *only* way any of the
    /// seven close-confirmation call sites across
    /// `WindowRuntime`/`AppStateStore`/`QuitConfirmation`/`RootWindowView`
    /// can be driven `true` today, in any environment — not even a running
    /// Beta with a real busy shell can do it, because the polyfill ignores
    /// the surface entirely.
    @ObservationIgnored
    var needsConfirmCloseOverride: Bool?

    public init(
        id: UUID = UUID(),
        titleOverride: String? = nil,
        workingDirectory: String? = nil,
        command: String? = nil,
        bellCount: Int = 0,
        unseenBellCount: Int = 0,
        lastBellAt: Date? = nil,
        lastBellMessage: String? = nil,
        backgroundGate: AppWideBackgroundGate = .live,
        paneBackgroundOverride: TerminalBackgroundSettings? = nil,
        sessionBackgroundOverride: TerminalBackgroundSettings? = nil,
        backgroundOverride: TerminalBackgroundSettings? = nil
    ) {
        self.id = id
        self.backgroundGate = backgroundGate
        self.backgroundOverride = backgroundOverride
        self.paneBackgroundOverride = paneBackgroundOverride
        self.sessionBackgroundOverride = sessionBackgroundOverride
        self.titleOverride = titleOverride
        self.workingDirectory = workingDirectory
        self.commandOverride = command
        let state = TerminalViewState(theme: Self.activeTheme())
        self.terminal = state
        self.terminalDelegate = TerminalDelegateProxy(state: state)
        if let workingDirectory {
            self.terminal.configuration.workingDirectory = workingDirectory
        }
        Self.applyShellAndAppearancePreferences(to: self.terminal, tabID: id, paneID: nil, sessionID: nil, command: command, background: Self.effectiveBackground(tab: backgroundOverride, pane: paneBackgroundOverride, session: sessionBackgroundOverride, gate: backgroundGate))
        self.bellCount = bellCount
        self.unseenBellCount = unseenBellCount
        self.lastBellAt = lastBellAt
        self.lastBellMessage = lastBellMessage
        terminalDelegate.tabID = id
        terminalDelegate.onStartupWaitingChange = { [weak self] waiting in
            self?.startupCommandWaiting = waiting
        }
        terminalDelegate.onRingBell = { [weak self] at in
            self?.receiveRingBell(at: at)
        }
        terminalDelegate.onDesktopNotification = { [weak self] title, body, at in
            self?.receiveDesktopNotification(title: title, body: body, at: at)
        }
        terminalDelegate.onTitleChange = { [weak self] title in
            self?.receiveTitleChange(title)
        }
        terminalDelegate.onCommandFinished = { [weak self] _, _ in
            self?.receiveCommandFinished()
        }
    }

    private static func activeTheme() -> TerminalTheme {
        guard let definition = ThemePreference.activeTheme() else { return .default }
        return definition.toTerminalTheme()
    }

    /// Types `command` into this Tab's shell once it reports its first working
    /// directory, as input followed by Return. At most once per call, however
    /// many further reports or re-mounts follow.
    public func armStartupCommand(_ command: String) {
        armStartupCommand(command, sink: TerminalStartupInputSink(tab: self))
    }

    @discardableResult
    func armStartupCommand(
        _ command: String,
        sink: any StartupInputSink,
        clock: any SchedulingClock = SystemClock()
    ) -> StartupCommandDelivery {
        let delivery = StartupCommandDelivery(command: command, sink: sink)
        terminalDelegate.armStartupCommand(delivery, clock: clock)
        return delivery
    }

    /// Run Now on the waiting indicator. Event-origin only (a button).
    public func runWaitingStartupCommand() {
        terminalDelegate.runStartupCommandNow()
    }

    /// Dismiss on the waiting indicator. Event-origin only (a button).
    public func dismissWaitingStartupCommand() {
        terminalDelegate.dismissStartupCommand()
    }

    /// Attaches this tab to its owning pane/session and (re-)applies the
    /// terminal configuration so the `BATTY_*` env vars carry the real ids.
    ///
    /// Ids aren't knowable at ``init(id:titleOverride:workingDirectory:bellCount:unseenBellCount:lastBellAt:lastBellMessage:)``
    /// time: a `TabRuntime` is constructed before the `PaneRuntime` that
    /// holds it exists (`PaneRuntime.init(tabs:)` takes already-built tabs),
    /// and that pane in turn is constructed before it joins a
    /// `SessionRuntime`'s `SplitTree` (#0281). Callers — `SessionRuntime.init`
    /// (initial tree), `PaneRuntime.addTab`, and `SplitTree.splitFocusedPane`/
    /// `splitFullDimension` (new panes) — call this as soon as the ids are
    /// known, which is always before the tab's libghostty surface can spawn:
    /// surface creation happens later, on first SwiftUI render
    /// (`TerminalHostStore.terminalView(for:windowID:)`, driven by
    /// `TerminalPlaceholderView.body`), never synchronously inside these
    /// model-construction call sites.
    ///
    /// Idempotent — a no-op if both ids already match, so re-attaching an
    /// already-attached tab (e.g. `SplitTree.attachToSession` walking every
    /// pane) doesn't re-render the ghostty config.
    public func attachContext(paneID: UUID, sessionID: UUID) {
        guard self.paneID != paneID || self.sessionID != sessionID else { return }
        self.paneID = paneID
        self.sessionID = sessionID
        Self.applyShellAndAppearancePreferences(to: terminal, tabID: id, paneID: paneID, sessionID: sessionID, command: commandOverride, background: Self.effectiveBackground(tab: backgroundOverride, pane: paneBackgroundOverride, session: sessionBackgroundOverride, gate: backgroundGate))
    }

    /// Goes through this Tab's own builder, so the per-Tab lines
    /// (`keybind = clear`, `command`, `copy-on-select`, `env BATTY_*`) survive
    /// the wholesale replace. Renders only if the winning override changed, so
    /// a Pane with its own override learns the Session's value, for when it's
    /// cleared, without touching its configuration. `clearingOwn` drops this
    /// Tab's own value, because a write from the Pane replaces it.
    func setBackgroundOverrides(pane: TerminalBackgroundSettings?, session: TerminalBackgroundSettings?, clearingOwn: Bool = false) {
        let previous = backgroundOverride ?? paneBackgroundOverride ?? sessionBackgroundOverride
        paneBackgroundOverride = pane
        sessionBackgroundOverride = session
        if clearingOwn {
            pendingTabImage = nil
            if backgroundOverride != nil { backgroundOverride = nil }
        }
        guard (backgroundOverride ?? pane ?? session) != previous else { return }
        render()
    }

    /// This Tab's own value. Idempotent because every observed write notifies,
    /// equal values included.
    public func setBackgroundOverride(_ newOverride: TerminalBackgroundSettings?) {
        guard newOverride != backgroundOverride else { return }
        let previous = backgroundOverride ?? paneBackgroundOverride ?? sessionBackgroundOverride
        backgroundOverride = newOverride
        pendingTabImage = nil
        guard (newOverride ?? paneBackgroundOverride ?? sessionBackgroundOverride) != previous else { return }
        render()
    }

    private func render() {
        Self.applyShellAndAppearancePreferences(to: terminal, tabID: id, paneID: paneID, sessionID: sessionID, command: commandOverride, background: Self.effectiveBackground(tab: backgroundOverride, pane: paneBackgroundOverride, session: sessionBackgroundOverride, gate: backgroundGate))
    }

    /// A new app-wide value, through this Tab's own builder for the same
    /// reason as ``setBackgroundOverrides(pane:session:)``.
    func refreshAppWideBackground(_ appWide: TerminalBackgroundSettings) {
        guard backgroundOverride == nil else { return }
        Self.applyShellAndAppearancePreferences(to: terminal, tabID: id, paneID: paneID, sessionID: sessionID, command: commandOverride, background: .effective(tab: nil, pane: paneBackgroundOverride, session: sessionBackgroundOverride, appWide: appWide))
    }

    /// New font and cursor values, through this Tab's own builder for the same
    /// reason as ``setBackgroundOverrides(pane:session:)``. Both arguments come
    /// from the store, whose `UserDefaults` and gate may not be this Tab's.
    func refreshAppearance(_ appearance: TerminalAppearance, appWide: TerminalBackgroundSettings) {
        Self.applyShellAndAppearancePreferences(to: terminal, tabID: id, paneID: paneID, sessionID: sessionID, command: commandOverride, background: .effective(tab: backgroundOverride, pane: paneBackgroundOverride, session: sessionBackgroundOverride, appWide: appWide), appearance: appearance)
    }

    private static func effectiveBackground(
        tab: TerminalBackgroundSettings?,
        pane: TerminalBackgroundSettings?,
        session: TerminalBackgroundSettings?,
        gate: AppWideBackgroundGate
    ) -> TerminalBackgroundSettings {
        .effective(tab: tab, pane: pane, session: session, appWide: gate.settings())
    }

    /// Left on the zero-arg, `.standard`-only `resolved…()` readers (#0426):
    /// unlike `AppStateStore`, `TabRuntime` has no owning store reference at
    /// either call site — `init` runs before any `PaneRuntime`/`SessionRuntime`
    /// exists to hold one, and `attachContext` only receives ids (see its doc
    /// comment on why). Threading a `UserDefaults` through here would mean
    /// widening `TabRuntime.init`, `PaneRuntime.init`, `SessionRuntime.init`,
    /// and every `SplitTree` construction path. No unit test writes
    /// `cursorStyleKey`/`cursorBlinkKey`/`fontSizeKey`/`defaultShellKey` on
    /// `.standard`, so there is nothing here for a concurrent test run to
    /// race — `SplitTreeTargetedSplitTests` does read `resolvedShell()` in an
    /// assertion, but only to compare production's rendered `command = …`
    /// line against a second same-process read of the same never-written
    /// key, which stays self-consistent regardless of what that key holds.
    ///
    /// `background` is the exception: tests must configure it, and they may
    /// not write `.standard`, so it comes from ``backgroundGate``, which only
    /// this `TabRuntime`'s own `init` parameter sets. `appearance` defaults to
    /// those `.standard` reads; ``refreshAppearance(_:appWide:)`` passes in the
    /// store's values instead.
    private static func applyShellAndAppearancePreferences(
        to terminal: TerminalViewState,
        tabID: UUID,
        paneID: UUID?,
        sessionID: UUID?,
        command: String? = nil,
        background: TerminalBackgroundSettings,
        appearance: TerminalAppearance = .resolved(defaults: .standard)
    ) {
        let shell = SettingsPreference.resolvedShell()
        let configuration = TerminalConfiguration { builder in
            // At this pin Ghostty's default `true` writes a selection to the
            // selection clipboard, and the package's `writeClipboard` discards
            // it (`TerminalController+Callbacks.swift`), so a selection doesn't
            // reach the system pasteboard with or without this line (measured,
            // #0538). It stays because it is what Batty declares, and a package
            // bump could change that discard. Cmd-C and Edit > Copy still copy
            // explicitly via the `cmd+c=copy_to_clipboard` keybind set below.
            builder.withCustom("copy-on-select", "false")
            // A per-tab command override (#0282's `pane split -c`) replaces
            // the shell preference entirely for this one tab, rather than
            // appending a second `command` line — `command`'s repeat-key
            // behavior in libghostty is unverified (unlike `env`, which
            // #0281 confirmed accumulates), so only one `command` line is
            // ever emitted.
            if let command, !command.isEmpty {
                builder.withCustom("command", command)
                // `-c` panes must survive their command exiting so the
                // output stays readable until the pane is closed
                // deliberately (#0282 round 3, user decision). Scoped to
                // `-c` panes only, by living in this same branch — an
                // ordinary shell tab must keep closing when the shell
                // exits, since Cmd-D and every existing tab rely on that.
                // `wait-after-command` verified against the pinned
                // libghostty (`a2565ccf047c03c74a59dd7c16a8fac7c477852f`,
                // tag 1.5.20260903) rather than assumed: `ghostty +show-config
                // --default --docs` documents `false` as the default and
                // "the terminal window will stay open until any keypress is
                // received" as the semantic; `true` round-trips with zero
                // config diagnostics through the real
                // `ghostty_config_new`/`load_file`/`finalize` pipeline
                // (`SplitTreeTargetedSplitTests`), and a deliberately
                // misspelled key produces `diagnostics=1 "unknown field"`
                // as the control proving that check is real.
                builder.withCustom("wait-after-command", "true")
                // libghostty's macOS exit heuristic (`Surface.childExited`,
                // upstream c4e16970a, the pinned ref) treats any exit with
                // runtime <= `abnormal-command-exit-runtime` (default 250)
                // as a failed launch regardless of exit code, and renders
                // the red "failed to launch the requested command" banner
                // instead of the plain "Process exited." line. A short
                // `-c` command is the normal case here, so `0` turns the
                // check off (the `login` wrapper makes a 0 ms runtime
                // implausible); `wait-after-command` still holds the pane
                // open. Shell panes keep the default.
                builder.withCustom("abnormal-command-exit-runtime", "0")
            } else if !shell.isEmpty {
                builder.withCustom("command", shell)
            }
            // Agent context (#0257/#0281): libghostty's `env` config
            // directive sets the spawned process's environment directly —
            // unlike prepending `export …;` to a shell command line, it
            // works whether or not a custom shell is configured (the
            // `command` block above is conditional; `env` isn't) and has no
            // shell-quoting hazard. paneID/sessionID are nil here at
            // `TabRuntime.init` time and filled in by `attachContext`
            // before the surface can spawn — see that method's doc.
            builder.withCustom("env", "BATTY_TAB_ID=\(tabID.uuidString)")
            if let paneID {
                builder.withCustom("env", "BATTY_PANE_ID=\(paneID.uuidString)")
            }
            if let sessionID {
                builder.withCustom("env", "BATTY_SESSION_ID=\(sessionID.uuidString)")
            }
            // Drop libghostty's default Cmd-* bindings (new_window, close_surface,
            // new_tab, new_split, goto_split, etc.) so they fall through to our
            // menu via performKeyEquivalent. Keep Cmd-C for copy because the menu
            // doesn't route through libghostty's copy buffer; paste goes through
            // our PasteDispatcher menu action.
            builder.withCustom("keybind", "clear")
            builder.withCustom("keybind", "cmd+c=copy_to_clipboard")
            // Last, because `keybind = clear` must precede the bindings this adds.
            builder.withSharedPreferences(fontSize: appearance.fontSize, cursor: appearance.cursor, blink: appearance.blink, background: background)
        }
        terminal.controller.setTerminalConfiguration(configuration)
    }

    /// Whether this Tab has a process libghostty reports as still needing
    /// confirmation to close. Single choke point every close-confirmation
    /// call site reads (#0398) instead of reaching past this indirection to
    /// `terminal.needsConfirmClose` directly — see
    /// ``needsConfirmCloseOverride``'s doc comment for what the override
    /// changes (tests only) and what it doesn't (the production signal).
    public var needsConfirmClose: Bool {
        needsConfirmCloseOverride ?? terminal.needsConfirmClose
    }

    /// Bridges libghostty's authoritative pwd signal into ``workingDirectory``
    /// by re-reading the live `terminal.workingDirectory` property.
    /// Idempotent (an equal-value write is skipped, matching the
    /// store-mutator convention in `docs/swiftui-observation-rules.md`) so
    /// repeat calls for a cwd that hasn't moved don't re-notify Observation.
    ///
    /// On-demand path only — call for the one-time initial-resolve check for
    /// a cwd libghostty may have already reported before the pwd delegate
    /// callback was wired. Do **not** call this from that callback itself:
    /// `TerminalViewState.workingDirectory`'s write is deferred to the next
    /// main-queue turn (`publishSoon`, libghostty-spm), so reading it back
    /// synchronously inside the callback that reported the change still
    /// observes the previous directory (#0436). The callback path uses
    /// ``applyReportedWorkingDirectory(_:)`` instead, which takes the
    /// reported path directly rather than re-reading the property.
    @discardableResult
    public func syncWorkingDirectoryFromTerminal() -> Bool {
        let resolved = terminal.workingDirectory ?? terminal.configuration.workingDirectory
        return applyWorkingDirectory(resolved)
    }

    /// Bridges the pwd delegate callback's reported path into
    /// ``workingDirectory`` directly, without re-reading
    /// `terminal.workingDirectory` — see
    /// ``syncWorkingDirectoryFromTerminal()``'s doc comment for why that
    /// property is unsafe to read back synchronously in that callback
    /// (#0436). Same idempotence as `syncWorkingDirectoryFromTerminal()`.
    @discardableResult
    public func applyReportedWorkingDirectory(_ path: String) -> Bool {
        applyWorkingDirectory(path)
    }

    @discardableResult
    private func applyWorkingDirectory(_ resolved: String?) -> Bool {
        guard resolved != workingDirectory else { return false }
        workingDirectory = resolved
        return true
    }

    func receiveRingBell(at: Date) {
        bellCount += 1
        lastBellAt = at
        lastBellMessage = nil
        if let bellIntake {
            bellIntake(self, .bel(count: 1, at: at))
        } else {
            pendingBells = (count: (pendingBells?.count ?? 0) + 1, lastAt: at)
        }
    }

    func receiveDesktopNotification(title: String, body: String, at: Date) {
        bellCount += 1
        lastBellAt = at
        let message = Self.formatNotification(title: title, body: body)
        lastBellMessage = message
        if let bellIntake {
            bellIntake(self, .desktopNotification(message: message, at: at))
        } else {
            pendingNotification = (message: message, at: at)
        }
    }

    /// Replaces any earlier intake, then delivers what rang before one was
    /// set: buffered BELs as one event stamped with the last of them, then
    /// the latest buffered notification.
    func setBellIntake(_ intake: @escaping (TabRuntime, BellIntakeEvent) -> Void) {
        bellIntake = intake
        if let pending = pendingBells {
            pendingBells = nil
            intake(self, .bel(count: pending.count, at: pending.lastAt))
        }
        if let pending = pendingNotification {
            pendingNotification = nil
            intake(self, .desktopNotification(message: pending.message, at: pending.at))
        }
    }

    public func markBellsSeen() {
        unseenBellCount = 0
    }

    /// Mirrors a reported OSC 2 title into ``terminalTitle`` and
    /// re-derives ``runningCommandDisplayName`` from it.
    ///
    /// Set-only: a registry hit assigns the display name. A miss does NOT
    /// clear — many TUIs (claude, vim, ssh) mutate their own OSC 2 title
    /// mid-session to show context (chat name, file path, host), and a
    /// strict "clear on any non-matching title" would wipe the chip the
    /// moment the TUI started doing its job. Clearing is the job of
    /// ``receiveCommandFinished()``.
    ///
    /// No equal-value guards here or in ``receiveCommandFinished()``: the
    /// `@Observable` setter already skips notifying when an `Equatable`
    /// property is assigned an equal value (`shouldNotifyObservers`).
    /// `TabTitleMirrorTests.equalTitleDoesNotRenotifyTheMirror` and
    /// `TabRuntimeRunningCommandTests.sameDisplayNameFromANewTitleDoesNotRenotify`
    /// pin that behaviour.
    func receiveTitleChange(_ title: String) {
        terminalTitle = title
        if let derived = TUIAppRegistry.displayNameFromTitle(title) {
            runningCommandDisplayName = derived
        }
    }

    /// Clears ``runningCommandDisplayName`` when libghostty reports a
    /// command finished (OSC 133 D). This is the only clear path: the
    /// title path is set-only, so a prompt title never clears the name.
    func receiveCommandFinished() {
        runningCommandDisplayName = nil
    }

    private static func formatNotification(title: String?, body: String?) -> String? {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (trimmedTitle?.isEmpty == false ? trimmedTitle : nil,
                trimmedBody?.isEmpty == false ? trimmedBody : nil) {
        case let (title?, body?):
            return "\(title): \(body)"
        case let (title?, nil):
            return title
        case let (nil, body?):
            return body
        default:
            return nil
        }
    }

}

public enum BellIntakeEvent: Equatable, Sendable {
    case bel(count: Int, at: Date)
    case desktopNotification(message: String?, at: Date)
}

extension TabRuntime: BackgroundOverrideHolder {
    func effectiveBackground(appWide: TerminalBackgroundSettings) -> EffectiveBackground {
        .first([(backgroundOverride, .tab), (paneBackgroundOverride, .pane), (sessionBackgroundOverride, .session)], appWide: appWide)
    }
}
