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
    public static let captureBellFeedDataKey = "co.sstools.Batty.captureBellFeedData"
    public static let backgroundImagePathKey = "co.sstools.Batty.backgroundImagePath"
    public static let backgroundImageFitKey = "co.sstools.Batty.backgroundImageFit"
    public static let backgroundImagePositionKey = "co.sstools.Batty.backgroundImagePosition"
    public static let backgroundImageOpacityKey = "co.sstools.Batty.backgroundImageOpacity"
    public static let backgroundOpacityKey = "co.sstools.Batty.backgroundOpacity"
    public static let backgroundOpacityCellsKey = "co.sstools.Batty.backgroundOpacityCells"

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
    public static let defaultCaptureBellFeedData: Bool = false
    public static let defaultBackgroundImageFit: String = BackgroundImageFit.contain.rawValue
    public static let defaultBackgroundImagePosition: String = BackgroundImagePosition.center.rawValue
    public static let defaultBackgroundImageOpacity: Double = 1
    public static let defaultBackgroundOpacity: Double = 1
    public static let defaultBackgroundOpacityCells: Bool = false
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

    static func resolvedCaptureBellFeedData(defaults: UserDefaults) -> Bool {
        if defaults.object(forKey: captureBellFeedDataKey) == nil {
            return defaultCaptureBellFeedData
        }
        return defaults.bool(forKey: captureBellFeedDataKey)
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

    /// Doesn't depend on `registerDefaults()`, which has no caller: an absent
    /// key must still produce the off state. Opacity checks for a number
    /// rather than `stored > 0` because `0` is a legal opacity, and
    /// `double(forKey:)` would turn a hand-edited string into `0`.
    /// Production reads this only through `AppWideBackgroundGate`.
    static func resolvedBackground(defaults: UserDefaults) -> TerminalBackgroundSettings {
        func opacity(_ key: String, default fallback: Double) -> Double {
            (defaults.object(forKey: key) as? NSNumber)?.doubleValue ?? fallback
        }
        return TerminalBackgroundSettings(
            imagePath: defaults.string(forKey: backgroundImagePathKey),
            fit: defaults.string(forKey: backgroundImageFitKey).flatMap(BackgroundImageFit.init(rawValue:))
                ?? BackgroundImageFit(rawValue: defaultBackgroundImageFit) ?? .contain,
            position: defaults.string(forKey: backgroundImagePositionKey).flatMap(BackgroundImagePosition.init(rawValue:))
                ?? BackgroundImagePosition(rawValue: defaultBackgroundImagePosition) ?? .center,
            imageOpacity: opacity(backgroundImageOpacityKey, default: defaultBackgroundImageOpacity),
            terminalOpacity: opacity(backgroundOpacityKey, default: defaultBackgroundOpacity),
            opacityAffectsCells: (defaults.object(forKey: backgroundOpacityCellsKey) as? NSNumber)?.boolValue ?? defaultBackgroundOpacityCells
        )
    }

    /// As real types, so `resolvedBackground(defaults:)` reads back what was
    /// written. A `nil` image removes the path key.
    static func writeBackground(_ background: TerminalBackgroundSettings, defaults: UserDefaults) {
        if let imagePath = background.imagePath {
            defaults.set(imagePath, forKey: backgroundImagePathKey)
        } else {
            defaults.removeObject(forKey: backgroundImagePathKey)
        }
        defaults.set(background.fit.rawValue, forKey: backgroundImageFitKey)
        defaults.set(background.position.rawValue, forKey: backgroundImagePositionKey)
        defaults.set(background.imageOpacity, forKey: backgroundImageOpacityKey)
        defaults.set(background.terminalOpacity, forKey: backgroundOpacityKey)
        defaults.set(background.opacityAffectsCells, forKey: backgroundOpacityCellsKey)
    }

    static func clearBackground(defaults: UserDefaults) {
        for key in [
            backgroundImagePathKey,
            backgroundImageFitKey,
            backgroundImagePositionKey,
            backgroundImageOpacityKey,
            backgroundOpacityKey,
            backgroundOpacityCellsKey,
        ] {
            defaults.removeObject(forKey: key)
        }
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

/// The preferences an appearance change alters, read once by whoever owns the
/// `UserDefaults` so every Tab of the push gets the same values.
struct TerminalAppearance {
    let fontSize: Float
    let cursor: TerminalCursorStyle
    let blink: Bool

    static func resolved(defaults: UserDefaults) -> TerminalAppearance {
        TerminalAppearance(
            fontSize: SettingsPreference.resolvedFontSize(defaults: defaults),
            cursor: TerminalCursorStyle(rawValue: SettingsPreference.resolvedCursorStyle(defaults: defaults)) ?? .block,
            blink: SettingsPreference.resolvedCursorBlink(defaults: defaults)
        )
    }
}

extension AppStateStore {
    public func applyAppearanceToAllSurfaces() {
        let appearance = TerminalAppearance.resolved(defaults: preferences)
        let appWideBackground = backgroundGate.settings()
        // Appearance settings are app-wide, so apply to every window's surfaces.
        // The `sessions` shim resolves to windows[0] only; iterating `windows`
        // directly avoids leaving other windows (often the key window) stale (#0248).
        for session in windows.flatMap({ $0.sessions }) {
            for pane in session.tree.allPanes {
                pane.refreshAppearance(appearance, appWide: appWideBackground)
            }
        }
    }
}

extension AppStateStore {
    /// Pushes the current app-wide background to every Pane following it.
    /// Goes through each Tab's own builder, as `applyAppearanceToAllSurfaces`
    /// does, so per-Tab lines survive (#0538).
    func applyAppWideBackgroundToAllSurfaces() {
        let appWide = backgroundGate.settings()
        setAppWideTerminalOpacity(appWide.terminalOpacity)
        for session in windows.flatMap({ $0.sessions }) {
            for pane in session.tree.allPanes {
                pane.refreshAppWideBackground(appWide)
            }
        }
    }
}

extension TerminalConfiguration.Builder {
    /// The font, cursor, shell-integration, `PATH`, line-editing keybind and
    /// background lines of a Tab's configuration. Must follow `keybind = clear`,
    /// which removes every binding before it.
    mutating func withSharedPreferences(
        fontSize: Float,
        cursor: TerminalCursorStyle,
        blink: Bool,
        background: TerminalBackgroundSettings
    ) {
        withFontSize(fontSize)
        withCursorStyle(cursor)
        withCursorStyleBlink(blink)
        // libghostty's default leaves `ssh-env` off, so `COLORTERM`/
        // `TERM_PROGRAM` never reach a remote host (#0392). Turning it on
        // declares Batty's intent correctly against libghostty's config
        // model, but the pinned `libghostty-spm` fork's bash/zsh
        // shell-integration scripts are a from-scratch MIT rewrite that
        // explicitly does not act on `ssh-env` (or `sudo`/`ssh-terminfo`/
        // `path`) — see docs/ssh-colors-and-terminfo.md. So this line is
        // currently a no-op in practice, kept for forward-compatibility
        // and because it is the correct declared config either way.
        // `ssh-terminfo` is deliberately left off: it writes to
        // `~/.terminfo` on whatever host `ssh` reaches, and #0392 was
        // told not to decide that trade-off unilaterally — see the
        // follow-up ticket. Every other feature (`cursor`, `no-sudo`,
        // `title`, `no-ssh-terminfo`, `path`) is omitted rather than
        // spelled out: per libghostty's own doc comment on this key, an
        // omitted feature keeps its default, so spelling out a value
        // identical to the default only widens the token list a future
        // pin bump could reject wholesale (one bad token here has been
        // observed to take the entire config down, `keybind = clear`
        // included) for zero behavioral gain. `ssh-env` is the only
        // actual delta from libghostty's default.
        withCustom("shell-integration-features", "ssh-env")
        // CLI/PATH collision (#0364): libghostty appends its own
        // executable directory (`Contents/MacOS`) to every spawned
        // shell's `PATH` via `GHOSTTY_BIN_DIR`, which on a
        // case-insensitive APFS volume collides with the app's own main
        // executable there — `Contents/MacOS/batty` and
        // `Contents/MacOS/Batty` name the same inode. Override `PATH`
        // outright so it points at the CLI's real location
        // (`Contents/Resources/bin`) instead, stripping the app's own
        // directory defensively. See `TabRuntimeCLIPathSeam`'s doc for
        // why an `env`-set `PATH` replaces rather than appends to
        // whatever libghostty already computed.
        withCustom("env", "PATH=\(TabRuntimeCLIPathSeam.injectedPath(basePath: ProcessInfo.processInfo.environment["PATH"], bundlePath: Bundle.main.bundlePath))")
        withCustom("keybind", "super+left=text:\\x01")
        withCustom("keybind", "super+right=text:\\x05")
        withCustom("keybind", "super+backspace=text:\\x15")
        withCustom("keybind", "alt+left=text:\\x1bb")
        withCustom("keybind", "alt+right=text:\\x1bf")
        withCustom("keybind", "alt+backspace=text:\\x1b\\x7f")
        withBackground(background)
    }

    /// Emits nothing for a setting that's off, so a user who never configures
    /// a background gets no new lines at all.
    private mutating func withBackground(_ background: TerminalBackgroundSettings) {
        if let imagePath = background.imagePath {
            // Quoted because libghostty trims unquoted whitespace from a value.
            withCustom("background-image", "\"\(imagePath)\"")
            withCustom("background-image-fit", background.fit.rawValue)
            withCustom("background-image-position", background.position.rawValue)
            // `description` rather than a localized format: `0,35` fails the
            // whole config.
            withCustom("background-image-opacity", background.imageOpacity.description)
        }
        if background.terminalOpacity < 1 {
            withBackgroundOpacity(background.terminalOpacity)
            if background.opacityAffectsCells {
                withCustom("background-opacity-cells", "true")
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
            backgroundImageFitKey: defaultBackgroundImageFit,
            backgroundImagePositionKey: defaultBackgroundImagePosition,
            backgroundImageOpacityKey: defaultBackgroundImageOpacity,
            backgroundOpacityKey: defaultBackgroundOpacity,
            backgroundOpacityCellsKey: defaultBackgroundOpacityCells,
        ])
    }
}
