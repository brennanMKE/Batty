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

    /// Long-lived libghostty NSView whose lifetime is bound to this tab,
    /// not to any SwiftUI representable. `StableTerminalSurfaceView`
    /// re-parents this view into fresh containers as SwiftUI rebuilds the
    /// view tree, preserving the underlying PTY and surface across tab
    /// switches, pane focus changes, and sidebar selection.
    @ObservationIgnored
    public internal(set) var terminalNSView: AppTerminalView?

    @ObservationIgnored
    private var lastObservedBellCount: Int = 0
    @ObservationIgnored
    private var lastObservedNotificationAt: Date?

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
