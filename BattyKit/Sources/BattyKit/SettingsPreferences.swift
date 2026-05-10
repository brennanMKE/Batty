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

    public static let defaultFontSize: Double = 13
    public static let defaultCursorStyle: String = "block"
    public static let defaultCursorBlink: Bool = true
    public static let defaultBellSound: Bool = true
    public static let defaultSystemNotifications: Bool = true

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
        }
        for session in sessions {
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
        ])
    }
}
