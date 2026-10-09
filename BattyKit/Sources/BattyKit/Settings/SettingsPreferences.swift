// SettingsPreferences.swift

import Darwin
import Foundation

public enum SettingsPreference {
    public static let defaultShellKey = "co.sstools.Batty.defaultShell"
    public static let fontSizeKey = "co.sstools.Batty.fontSize"
    public static let cursorStyleKey = "co.sstools.Batty.cursorStyle"
    public static let cursorBlinkKey = "co.sstools.Batty.cursorBlink"
    public static let bellSoundKey = "co.sstools.Batty.bellSound"
    public static let systemNotificationsKey = "co.sstools.Batty.systemNotifications"
    public static let pasteStrictnessKey = "co.sstools.Batty.pasteStrictness"
    public static let confirmQuitKey = "co.sstools.Batty.confirmQuit"
    public static let cmdNumberTargetKey = "co.sstools.Batty.cmdNumberTarget"
    public static let autoNameFromFilesKey = "co.sstools.Batty.autoNameFromFiles"
    public static let autoNameWithAIKey = "co.sstools.Batty.autoNameWithAI"
    public static let summarizeNotificationsWithAIKey = "co.sstools.Batty.summarizeNotificationsWithAI"
    public static let footprintSoftLimitGBKey = "co.sstools.Batty.footprintSoftLimitGB"

    public static let defaultFontSize: Double = 13
    public static let defaultCursorStyle: String = "block"
    public static let defaultCursorBlink: Bool = true
    public static let defaultBellSound: Bool = true
    public static let defaultSystemNotifications: Bool = true
    public static let defaultPasteStrictness: String = PasteStrictness.never.rawValue
    public static let defaultConfirmQuit: Bool = true
    public static let defaultCmdNumberTarget: String = CmdNumberTarget.sessions.rawValue
    public static let defaultAutoNameFromFiles: Bool = true
    public static let defaultAutoNameWithAI: Bool = true
    public static let defaultSummarizeNotificationsWithAI: Bool = true
    /// #0285's field measurements put graphics cost at ~42-56 MB per open
    /// Terminal Session. 4 GB gives comfortable headroom for the sizes of
    /// workspace people actually run (dozens of sessions) while still
    /// warning well before the 8+ GB level that pushed the reporting
    /// machine into kernel memory pressure.
    public static let defaultFootprintSoftLimitGB: Double = 4.0

    public static func detectedShell() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        if let pw = getpwuid(getuid()), let shellPtr = pw.pointee.pw_shell {
            let detected = String(cString: shellPtr)
            if !detected.isEmpty { return detected }
        }
        return "/bin/bash"
    }

    public static func resolvedShell() -> String {
        let stored = UserDefaults.standard.string(forKey: defaultShellKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? detectedShell() : stored
    }

    public static func resolvedFontSize() -> Float {
        resolvedFontSize(defaults: .standard)
    }

    static func resolvedFontSize(defaults: UserDefaults) -> Float {
        let stored = defaults.double(forKey: fontSizeKey)
        return stored > 0 ? Float(stored) : Float(defaultFontSize)
    }

    public static func resolvedCursorStyle() -> String {
        resolvedCursorStyle(defaults: .standard)
    }

    static func resolvedCursorStyle(defaults: UserDefaults) -> String {
        let stored = defaults.string(forKey: cursorStyleKey) ?? ""
        return stored.isEmpty ? defaultCursorStyle : stored
    }

    public static func resolvedCursorBlink() -> Bool {
        resolvedCursorBlink(defaults: .standard)
    }

    static func resolvedCursorBlink(defaults: UserDefaults) -> Bool {
        if defaults.object(forKey: cursorBlinkKey) == nil {
            return defaultCursorBlink
        }
        return defaults.bool(forKey: cursorBlinkKey)
    }

    public static func resolvedBellSound() -> Bool {
        if UserDefaults.standard.object(forKey: bellSoundKey) == nil {
            return defaultBellSound
        }
        return UserDefaults.standard.bool(forKey: bellSoundKey)
    }

    public static func resolvedSystemNotifications() -> Bool {
        resolvedSystemNotifications(defaults: .standard)
    }

    static func resolvedSystemNotifications(defaults: UserDefaults) -> Bool {
        if defaults.object(forKey: systemNotificationsKey) == nil {
            return defaultSystemNotifications
        }
        return defaults.bool(forKey: systemNotificationsKey)
    }

    static func resolvedPasteStrictness(defaults: UserDefaults) -> PasteStrictness {
        let raw = defaults.string(forKey: pasteStrictnessKey) ?? defaultPasteStrictness
        return PasteStrictness(rawValue: raw) ?? .never
    }

    /// The only `resolvedConfirmQuit` — no `.standard`-only zero-arg version
    /// exists (deleted, #0426: it had no caller). Production reaches this
    /// through two call sites, both of which pass a store's `preferences`
    /// (`.standard` unless a test injected something else):
    /// `QuitConfirmation.shouldQuitOrPrompt(store:)` and
    /// `QuitConfirmation.windowNeedsConfirmClose(window:defaults:)` (whose
    /// only caller, `WindowDelegate` in `Views/RootWindowView.swift`, passes
    /// the owning store's `preferences`).
    static func resolvedConfirmQuit(defaults: UserDefaults) -> Bool {
        if defaults.object(forKey: confirmQuitKey) == nil {
            return defaultConfirmQuit
        }
        return defaults.bool(forKey: confirmQuitKey)
    }

    static func resolvedAutoNameFromFiles(defaults: UserDefaults) -> Bool {
        if defaults.object(forKey: autoNameFromFilesKey) == nil {
            return defaultAutoNameFromFiles
        }
        return defaults.bool(forKey: autoNameFromFilesKey)
    }

    static func resolvedAutoNameWithAI(defaults: UserDefaults) -> Bool {
        if defaults.object(forKey: autoNameWithAIKey) == nil {
            return defaultAutoNameWithAI
        }
        return defaults.bool(forKey: autoNameWithAIKey)
    }

    static func resolvedSummarizeNotificationsWithAI(defaults: UserDefaults) -> Bool {
        if defaults.object(forKey: summarizeNotificationsWithAIKey) == nil {
            return defaultSummarizeNotificationsWithAI
        }
        return defaults.bool(forKey: summarizeNotificationsWithAIKey)
    }

    static func resolvedFootprintSoftLimitGB(defaults: UserDefaults) -> Double {
        let stored = defaults.double(forKey: footprintSoftLimitGBKey)
        return stored > 0 ? stored : defaultFootprintSoftLimitGB
    }

    public static func resolvedFootprintSoftLimitBytes() -> UInt64 {
        resolvedFootprintSoftLimitBytes(defaults: .standard)
    }

    static func resolvedFootprintSoftLimitBytes(defaults: UserDefaults) -> UInt64 {
        UInt64((resolvedFootprintSoftLimitGB(defaults: defaults) * 1_073_741_824).rounded())
    }
}

public enum PasteStrictness: String, CaseIterable, Sendable {
    case alwaysOnMultiline
    case onShellMetacharacters
    case never

    public var displayName: String {
        switch self {
        case .alwaysOnMultiline: return String(localized: "Always confirm multi-line")
        case .onShellMetacharacters: return String(localized: "Confirm only with shell metacharacters")
        case .never: return String(localized: "Never confirm")
        }
    }

    public func shouldConfirm(_ text: String) -> Bool {
        switch self {
        case .never:
            return false
        case .alwaysOnMultiline:
            return text.contains("\n")
        case .onShellMetacharacters:
            guard text.contains("\n") else { return false }
            let dangerous = ["rm ", "sudo ", "dd ", " > /", " | sh", "&&", ";"]
            return dangerous.contains(where: text.contains)
        }
    }
}

public enum CmdNumberTarget: String, CaseIterable, Sendable {
    case sessions
    case tabs

    public var displayName: String {
        switch self {
        case .sessions: return String(localized: "Sessions")
        case .tabs:     return String(localized: "Tabs")
        }
    }
}

extension AppStateStore {
    public func applyAppearanceToAllSurfaces() {
        let cursor = TerminalCursorStyle(rawValue: SettingsPreference.resolvedCursorStyle(defaults: preferences)) ?? .block
        let blink = SettingsPreference.resolvedCursorBlink(defaults: preferences)
        let fontSize = SettingsPreference.resolvedFontSize(defaults: preferences)
        let configuration = TerminalConfiguration { builder in
            builder.withFontSize(fontSize)
            builder.withCursorStyle(cursor)
            builder.withCursorStyleBlink(blink)
            // Emits the same `shell-integration-features` value as
            // `TabRuntime.applyShellAndAppearancePreferences` (#0392) —
            // `setTerminalConfiguration` replaces rather than merges, so a
            // key emitted from only one of the two builders is silently
            // dropped the next time the other one runs. (This builder still
            // omits `copy-on-select`, `command`, `env BATTY_*`,
            // `keybind = clear`, and `cmd+c` — #0373's pre-existing gap, not
            // fixed here.) Consumed at process spawn, so reapplying here
            // can't affect an already-running shell; what it does protect is
            // a Tab created *before* an appearance change whose surface
            // hasn't spawned yet — a Tab created after the change already
            // gets the key from `TabRuntime`'s own builder. Only `ssh-env`
            // is spelled out; every other feature is left at libghostty's
            // default by omission — see the sibling comment in
            // `TabRuntime.swift` for why that's deliberate.
            builder.withCustom("shell-integration-features", "ssh-env")
            // The `env PATH=…` override (#0364) is the one line from
            // `TabRuntime`'s builder this one does *not* omit deliberately —
            // `setTerminalConfiguration` replaces rather than merges (see
            // above), so a Tab created before an appearance change but whose
            // surface hasn't spawned yet would otherwise come back up with
            // `Contents/MacOS` back on `PATH` the moment this builder's
            // config lands. Must stay in sync with `TabRuntime`'s own
            // `env PATH=…` line.
            builder.withCustom("env", "PATH=\(TabRuntimeCLIPathSeam.injectedPath(basePath: ProcessInfo.processInfo.environment["PATH"], bundlePath: Bundle.main.bundlePath))")
            builder.withCustom("keybind", "super+left=text:\\x01")
            builder.withCustom("keybind", "super+right=text:\\x05")
            builder.withCustom("keybind", "super+backspace=text:\\x15")
            builder.withCustom("keybind", "alt+left=text:\\x1bb")
            builder.withCustom("keybind", "alt+right=text:\\x1bf")
            builder.withCustom("keybind", "alt+backspace=text:\\x1b\\x7f")
        }
        // Appearance settings are app-wide, so apply to every window's surfaces.
        // The `sessions` shim resolves to windows[0] only; iterating `windows`
        // directly avoids leaving other windows (often the key window) stale (#0248).
        // A non-terminal pane's `tabs` holds one structural placeholder
        // `TabRuntime` (`PaneRuntime.kind`'s doc comment) — its
        // `TerminalController` was never attached to a rendered surface, so
        // reconfiguring it is wasted work with no visible effect (#0315
        // review round 1, finding 3).
        for session in windows.flatMap({ $0.sessions }) {
            for pane in session.tree.allPanes where pane.kind == .terminal {
                for tab in pane.tabs {
                    tab.terminal.controller.setTerminalConfiguration(configuration)
                }
            }
        }
    }
}

extension SettingsPreference {
    public static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            fontSizeKey: defaultFontSize,
            cursorStyleKey: defaultCursorStyle,
            cursorBlinkKey: defaultCursorBlink,
            bellSoundKey: defaultBellSound,
            systemNotificationsKey: defaultSystemNotifications,
            cmdNumberTargetKey: defaultCmdNumberTarget,
            footprintSoftLimitGBKey: defaultFootprintSoftLimitGB,
        ])
    }
}
