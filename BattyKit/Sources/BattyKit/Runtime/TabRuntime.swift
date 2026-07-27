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

    /// Observation-tracked mirror of `terminal.workingDirectory`. That
    /// property is Combine `@Published` on an `ObservableObject`
    /// (`TerminalViewState`, from the GhosttyTerminal package), which the
    /// `@Observable` view layer does not track — reading it from `body`
    /// left tab chips and the sidebar pane row stuck on the tab's initial
    /// directory after `cd` (#0260, following the session-title staleness
    /// fixed the same way in #0227). View-reachable code (``TabTitleFormatter``)
    /// must read this mirror, never `terminal.workingDirectory` directly;
    /// non-view event-handler code (``AppStateStore``) may still read the
    /// live Combine value since it isn't gated by Observation there.
    /// Written only via ``syncWorkingDirectoryFromTerminal()``, called from
    /// the pwd delegate callback (event-origin, not view-update code).
    public internal(set) var workingDirectory: String?

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
    /// per-window ``TerminalHostView`` on first appearance and removes it
    /// on tab close); this property is the canonical back-reference for
    /// tests and any tab-scoped consumer that needs the view directly.
    /// Treat it as read-mostly — the host store is the authority.
    @ObservationIgnored
    public internal(set) var terminalNSView: AppTerminalView?

    @ObservationIgnored
    let terminalDelegate: TerminalDelegateProxy

    @ObservationIgnored
    private var lastObservedBellCount: Int = 0
    @ObservationIgnored
    private var lastObservedNotificationAt: Date?
    @ObservationIgnored
    private var lastObservedCommandDurationNanos: UInt64?

    public init(
        id: UUID = UUID(),
        titleOverride: String? = nil,
        workingDirectory: String? = nil,
        command: String? = nil,
        bellCount: Int = 0,
        unseenBellCount: Int = 0,
        lastBellAt: Date? = nil,
        lastBellMessage: String? = nil
    ) {
        self.id = id
        self.titleOverride = titleOverride
        self.workingDirectory = workingDirectory
        self.commandOverride = command
        let state = TerminalViewState(theme: Self.activeTheme())
        self.terminal = state
        self.terminalDelegate = TerminalDelegateProxy(state: state)
        if let workingDirectory {
            self.terminal.configuration.workingDirectory = workingDirectory
        }
        Self.applyShellAndAppearancePreferences(to: self.terminal, tabID: id, paneID: nil, sessionID: nil, command: command)
        self.bellCount = bellCount
        self.unseenBellCount = unseenBellCount
        self.lastBellAt = lastBellAt
        self.lastBellMessage = lastBellMessage
    }

    private static func activeTheme() -> TerminalTheme {
        guard let definition = ThemePreference.activeTheme() else { return .default }
        return definition.toTerminalTheme()
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
        Self.applyShellAndAppearancePreferences(to: terminal, tabID: id, paneID: paneID, sessionID: sessionID, command: commandOverride)
    }

    private static func applyShellAndAppearancePreferences(
        to terminal: TerminalViewState,
        tabID: UUID,
        paneID: UUID?,
        sessionID: UUID?,
        command: String? = nil
    ) {
        let cursor = TerminalCursorStyle(rawValue: SettingsPreference.resolvedCursorStyle()) ?? .block
        let blink = SettingsPreference.resolvedCursorBlink()
        let fontSize = SettingsPreference.resolvedFontSize()
        let shell = SettingsPreference.resolvedShell()
        let configuration = TerminalConfiguration { builder in
            builder.withFontSize(fontSize)
            builder.withCursorStyle(cursor)
            builder.withCursorStyleBlink(blink)
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
                // libghostty (`c69c34354e511af7a3e6d7e5e2a4fa2fed4b90ff`)
                // rather than assumed: `ghostty +show-config --default
                // --docs` documents `false` as the default and "the
                // terminal window will stay open until any keypress is
                // received" as the semantic; `true` round-trips with zero
                // config diagnostics through the real
                // `ghostty_config_new`/`load_file`/`finalize` pipeline
                // (`SplitTreeTargetedSplitTests`), and a deliberately
                // misspelled key produces `diagnostics=1 "unknown field"`
                // as the control proving that check is real.
                builder.withCustom("wait-after-command", "true")
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
            builder.withCustom("keybind", "super+left=text:\\x01")
            builder.withCustom("keybind", "super+right=text:\\x05")
            builder.withCustom("keybind", "super+backspace=text:\\x15")
            builder.withCustom("keybind", "alt+left=text:\\x1bb")
            builder.withCustom("keybind", "alt+right=text:\\x1bf")
            builder.withCustom("keybind", "alt+backspace=text:\\x1b\\x7f")
        }
        terminal.controller.setTerminalConfiguration(configuration)
    }

    /// Bridges libghostty's authoritative pwd signal into ``workingDirectory``.
    /// Idempotent (an equal-value write is skipped, matching the
    /// store-mutator convention in `docs/swiftui-observation-rules.md`) so
    /// repeat calls for a cwd that hasn't moved don't re-notify Observation.
    /// Call from event-driven contexts only: the pwd delegate callback, and
    /// the one-time initial-resolve check for a cwd libghostty may have
    /// already reported before the callback was wired.
    @discardableResult
    public func syncWorkingDirectoryFromTerminal() -> Bool {
        let resolved = terminal.workingDirectory ?? terminal.configuration.workingDirectory
        guard resolved != workingDirectory else { return false }
        workingDirectory = resolved
        return true
    }

    @discardableResult
    public func recordBellTickIfNeeded() -> Int {
        let observed = terminal.bellCount
        guard observed > lastObservedBellCount else { return 0 }
        let delta = observed - lastObservedBellCount
        lastObservedBellCount = observed
        bellCount += delta
        lastBellAt = terminal.lastBellAt ?? Date()
        lastBellMessage = nil
        return delta
    }

    @discardableResult
    public func recordDesktopNotificationIfNeeded() -> Bool {
        guard let at = terminal.lastDesktopNotificationAt else { return false }
        guard at != lastObservedNotificationAt else { return false }
        lastObservedNotificationAt = at
        bellCount += 1
        lastBellAt = at
        lastBellMessage = Self.formatNotification(
            title: terminal.lastDesktopNotificationTitle,
            body: terminal.lastDesktopNotificationBody
        )
        return true
    }

    public func markBellsSeen() {
        unseenBellCount = 0
    }

    /// Re-derive ``runningCommandDisplayName`` from the surface's current
    /// OSC 2 title. Called whenever ``TerminalViewState.title`` changes.
    ///
    /// Set-only: a registry hit assigns the display name. A miss does NOT
    /// clear — many TUIs (claude, vim, ssh) mutate their own OSC 2 title
    /// mid-session to show context (chat name, file path, host), and a
    /// strict "clear on any non-matching title" would wipe the chip the
    /// moment the TUI started doing its job. Clearing is the
    /// responsibility of ``recordCommandFinishedIfNeeded`` (driven by
    /// libghostty's OSC 133 D command-finished signal).
    public func refreshRunningCommandFromTitle() {
        guard let derived = TUIAppRegistry.displayNameFromTitle(terminal.title) else {
            return
        }
        if derived != runningCommandDisplayName {
            runningCommandDisplayName = derived
        }
    }

    /// Clears ``runningCommandDisplayName`` once when libghostty reports a
    /// command finished via OSC 133 D. Returns `true` if the call cleared
    /// the field (i.e. the duration moved since the last observation).
    ///
    /// Acts as a backstop for shells that don't emit a prompt OSC 2 on
    /// command exit; with oh-my-zsh's precmd the title-driven path already
    /// clears, but this guards against shell configs that skip that step.
    @discardableResult
    public func recordCommandFinishedIfNeeded() -> Bool {
        let observed = terminal.lastCommandDurationNanos
        guard observed != lastObservedCommandDurationNanos else { return false }
        lastObservedCommandDurationNanos = observed
        guard observed != nil else { return false }
        if runningCommandDisplayName != nil {
            runningCommandDisplayName = nil
        }
        return true
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
