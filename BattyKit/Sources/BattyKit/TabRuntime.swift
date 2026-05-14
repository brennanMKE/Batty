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
    private var lastObservedBellCount: Int = 0
    @ObservationIgnored
    private var lastObservedNotificationAt: Date?
    @ObservationIgnored
    private var lastObservedCommandDurationNanos: UInt64?

    public init(
        id: UUID = UUID(),
        titleOverride: String? = nil,
        workingDirectory: String? = nil,
        bellCount: Int = 0,
        unseenBellCount: Int = 0,
        lastBellAt: Date? = nil,
        lastBellMessage: String? = nil
    ) {
        self.id = id
        self.titleOverride = titleOverride
        self.terminal = TerminalViewState(theme: Self.activeTheme())
        if let workingDirectory {
            self.terminal.configuration.workingDirectory = workingDirectory
        }
        Self.applyShellAndAppearancePreferences(to: self.terminal)
        self.bellCount = bellCount
        self.unseenBellCount = unseenBellCount
        self.lastBellAt = lastBellAt
        self.lastBellMessage = lastBellMessage
    }

    private static func applyShellAndAppearancePreferences(to terminal: TerminalViewState) {
        let cursor = TerminalCursorStyle(rawValue: SettingsPreference.resolvedCursorStyle()) ?? .block
        let blink = SettingsPreference.resolvedCursorBlink()
        let fontSize = SettingsPreference.resolvedFontSize()
        let shell = SettingsPreference.resolvedShell()
        let configuration = TerminalConfiguration { builder in
            builder.withFontSize(fontSize)
            builder.withCursorStyle(cursor)
            builder.withCursorStyleBlink(blink)
            if !shell.isEmpty {
                builder.withCustom("command", shell)
            }
            // Drop libghostty's default Cmd-* bindings (new_window, close_surface,
            // new_tab, new_split, goto_split, etc.) so they fall through to our
            // menu via performKeyEquivalent. Keep Cmd-C for copy because the menu
            // doesn't route through libghostty's copy buffer; paste goes through
            // our PasteDispatcher menu action.
            builder.withCustom("keybind", "clear")
            builder.withCustom("keybind", "cmd+c=copy_to_clipboard")
            builder.withCustom("macos-option-as-alt", "true")
            builder.withCustom("keybind", "super+left=text:\\x01")
            builder.withCustom("keybind", "super+right=text:\\x05")
            builder.withCustom("keybind", "super+backspace=text:\\x15")
        }
        terminal.controller.setTerminalConfiguration(configuration)
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

    private static func activeTheme() -> TerminalTheme {
        guard
            let name = UserDefaults.standard.string(forKey: ThemePreference.defaultsKey),
            !name.isEmpty,
            let definition = GhosttyThemeCatalog.theme(named: name)
        else {
            return .default
        }
        return definition.toTerminalTheme()
    }
}
