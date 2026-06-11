// SettingsView.swift

import SwiftUI

public struct SettingsView: View {
    @Environment(\.appStateStore) private var store

    public init() {}

    public var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }

            AppearanceSettingsView(store: store)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }

            ShortcutsSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }

            NotificationsSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell") }
        }
        .frame(minWidth: 460, minHeight: 320)
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(SettingsPreference.defaultShellKey) private var shellOverride: String = ""
    @AppStorage(SettingsPreference.pasteStrictnessKey) private var pasteStrictness: String = SettingsPreference.defaultPasteStrictness
    @AppStorage(SettingsPreference.confirmQuitKey) private var confirmQuit: Bool = SettingsPreference.defaultConfirmQuit
    @AppStorage(SettingsPreference.cmdNumberTargetKey) private var cmdNumberTarget: String = SettingsPreference.defaultCmdNumberTarget
    @AppStorage(SettingsPreference.autoNameFromFilesKey) private var autoNameFromFiles: Bool = SettingsPreference.defaultAutoNameFromFiles
    @AppStorage(SettingsPreference.autoNameWithAIKey) private var autoNameWithAI: Bool = SettingsPreference.defaultAutoNameWithAI

    private var aiNamingSupported: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    var body: some View {
        Form {
            Section("Default Shell") {
                TextField(
                    "Shell path",
                    text: $shellOverride,
                    prompt: Text(SettingsPreference.detectedShell())
                )
                .textFieldStyle(.roundedBorder)
                Text("Auto-detected: \(SettingsPreference.detectedShell())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Paste Confirmation") {
                Picker("On Cmd-V", selection: $pasteStrictness) {
                    ForEach(PasteStrictness.allCases, id: \.rawValue) { strictness in
                        Text(strictness.displayName).tag(strictness.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Text("Confirms before injecting potentially risky text. Cmd-V to a TextField is unaffected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Quit") {
                Toggle("Confirm quit when terminals are open", isOn: $confirmQuit)
                Text("Counts open tabs across all sessions; the prompt fires only when at least one tab exists.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Session Naming") {
                Toggle("Name sessions from project files", isOn: $autoNameFromFiles)
                Toggle("Use Apple Intelligence to suggest names", isOn: $autoNameWithAI)
                    .disabled(!aiNamingSupported)
                if aiNamingSupported {
                    Text("Applies when the shell changes directory. Manual renames always win.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Requires macOS 26")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Keyboard") {
                Picker("Cmd-1…9 switches", selection: $cmdNumberTarget) {
                    ForEach(CmdNumberTarget.allCases, id: \.rawValue) { target in
                        Text(target.displayName).tag(target.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text("Sessions: jump to session 1–9 with Cmd-1…9, tabs with Cmd-Option-1…9. Tabs: reversed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

private struct AppearanceSettingsView: View {
    let store: AppStateStore?

    @AppStorage(SettingsPreference.fontSizeKey) private var fontSize: Double = SettingsPreference.defaultFontSize
    @AppStorage(SettingsPreference.cursorStyleKey) private var cursorStyle: String = SettingsPreference.defaultCursorStyle
    @AppStorage(SettingsPreference.cursorBlinkKey) private var cursorBlink: Bool = SettingsPreference.defaultCursorBlink
    @AppStorage(ThemePreference.defaultsKey) private var themeName: String = ""

    var body: some View {
        Form {
            Section("Font") {
                HStack {
                    Stepper(
                        "Size: \(Int(fontSize))pt",
                        value: $fontSize,
                        in: 8...32,
                        step: 1
                    )
                }
                .onChange(of: fontSize) { applyAppearance() }
            }

            Section("Cursor") {
                Picker("Style", selection: $cursorStyle) {
                    Text("Block").tag("block")
                    Text("Bar").tag("bar")
                    Text("Underline").tag("underline")
                }
                .pickerStyle(.segmented)
                .onChange(of: cursorStyle) { applyAppearance() }

                Toggle("Blink", isOn: $cursorBlink)
                    .onChange(of: cursorBlink) { applyAppearance() }
            }

            Section("Theme") {
                Picker("Theme", selection: $themeName) {
                    Text("Default").tag("")
                    ForEach(GhosttyThemeCatalog.allThemes, id: \.id) { theme in
                        Text(theme.name).tag(theme.name)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: themeName) { _, newValue in
                    guard let store, !newValue.isEmpty,
                          let theme = GhosttyThemeCatalog.theme(named: newValue)
                    else { return }
                    store.applyThemeToAllSurfaces(theme)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    private func applyAppearance() {
        store?.applyAppearanceToAllSurfaces()
    }
}

private struct NotificationsSettingsView: View {
    @AppStorage(SettingsPreference.bellSoundKey) private var bellSound: Bool = SettingsPreference.defaultBellSound
    @AppStorage(SettingsPreference.systemNotificationsKey) private var systemNotifications: Bool = SettingsPreference.defaultSystemNotifications

    var body: some View {
        Form {
            Section("Bell") {
                Toggle("Play sound", isOn: $bellSound)
                Toggle("Show system notifications", isOn: $systemNotifications)
            }
            Text("Per-Session mute lives on the Session row's right-click menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
        .formStyle(.grouped)
        .padding(20)
    }
}
