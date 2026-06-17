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
        let stored = UserDefaults.standard.double(forKey: fontSizeKey)
        return stored > 0 ? Float(stored) : Float(defaultFontSize)
    }

    public static func resolvedCursorStyle() -> String {
        let stored = UserDefaults.standard.string(forKey: cursorStyleKey) ?? ""
        return stored.isEmpty ? defaultCursorStyle : stored
    }

    public static func resolvedCursorBlink() -> Bool {
        if UserDefaults.standard.object(forKey: cursorBlinkKey) == nil {
            return defaultCursorBlink
        }
        return UserDefaults.standard.bool(forKey: cursorBlinkKey)
    }

    public static func resolvedBellSound() -> Bool {
        if UserDefaults.standard.object(forKey: bellSoundKey) == nil {
            return defaultBellSound
        }
        return UserDefaults.standard.bool(forKey: bellSoundKey)
    }

    public static func resolvedSystemNotifications() -> Bool {
        if UserDefaults.standard.object(forKey: systemNotificationsKey) == nil {
            return defaultSystemNotifications
        }
        return UserDefaults.standard.bool(forKey: systemNotificationsKey)
    }

    public static func resolvedPasteStrictness() -> PasteStrictness {
        let raw = UserDefaults.standard.string(forKey: pasteStrictnessKey) ?? defaultPasteStrictness
        return PasteStrictness(rawValue: raw) ?? .never
    }

    public static func resolvedConfirmQuit() -> Bool {
        if UserDefaults.standard.object(forKey: confirmQuitKey) == nil {
            return defaultConfirmQuit
        }
        return UserDefaults.standard.bool(forKey: confirmQuitKey)
    }

    public static func resolvedAutoNameFromFiles() -> Bool {
        if UserDefaults.standard.object(forKey: autoNameFromFilesKey) == nil {
            return defaultAutoNameFromFiles
        }
        return UserDefaults.standard.bool(forKey: autoNameFromFilesKey)
    }

    public static func resolvedAutoNameWithAI() -> Bool {
        if UserDefaults.standard.object(forKey: autoNameWithAIKey) == nil {
            return defaultAutoNameWithAI
        }
        return UserDefaults.standard.bool(forKey: autoNameWithAIKey)
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
        let cursor = TerminalCursorStyle(rawValue: SettingsPreference.resolvedCursorStyle()) ?? .block
        let blink = SettingsPreference.resolvedCursorBlink()
        let fontSize = SettingsPreference.resolvedFontSize()
        let configuration = TerminalConfiguration { builder in
            builder.withFontSize(fontSize)
            builder.withCursorStyle(cursor)
            builder.withCursorStyleBlink(blink)
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
        for session in windows.flatMap({ $0.sessions }) {
            for pane in session.tree.allPanes {
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
        ])
    }
}
