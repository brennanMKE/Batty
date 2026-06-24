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

            AdvancedSettingsView()
                .tabItem { Label("Advanced", systemImage: "terminal") }
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
    @AppStorage(ThemePreference.darkDefaultsKey) private var darkThemeName: String = ""
    @AppStorage(ThemePreference.lightDefaultsKey) private var lightThemeName: String = ""
    @Environment(\.colorScheme) private var colorScheme

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
                themePicker("Light", selection: $lightThemeName, appliesNow: colorScheme == .light)
                themePicker("Dark", selection: $darkThemeName, appliesNow: colorScheme == .dark)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    /// A per-appearance theme picker. `appliesNow` is true for the slot that
    /// matches the currently-displayed appearance — only that slot re-themes
    /// live surfaces on change. The off-appearance slot just persists; the
    /// `AppearanceObserver` applies it when the system switches to it.
    @ViewBuilder
    private func themePicker(_ label: String, selection: Binding<String>, appliesNow: Bool) -> some View {
        Picker(label, selection: selection) {
            Text("Default").tag("")
            ForEach(GhosttyThemeCatalog.allThemes, id: \.id) { theme in
                Text(theme.name).tag(theme.name)
            }
        }
        .pickerStyle(.menu)
        .onChange(of: selection.wrappedValue) { _, newValue in
            guard appliesNow, let store, !newValue.isEmpty,
                  let theme = GhosttyThemeCatalog.theme(named: newValue)
            else { return }
            store.applyThemeToAllSurfaces(theme)
        }
    }

    private func applyAppearance() {
        store?.applyAppearanceToAllSurfaces()
    }
}

private struct NotificationsSettingsView: View {
    @AppStorage(SettingsPreference.bellSoundKey) private var bellSound: Bool = SettingsPreference.defaultBellSound
    @AppStorage(SettingsPreference.systemNotificationsKey) private var systemNotifications: Bool = SettingsPreference.defaultSystemNotifications
    @AppStorage(SettingsPreference.summarizeNotificationsWithAIKey) private var summarizeWithAI: Bool = SettingsPreference.defaultSummarizeNotificationsWithAI

    private var aiSummarySupported: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    var body: some View {
        Form {
            Section("Bell") {
                Toggle("Play sound", isOn: $bellSound)
                Toggle("Show system notifications", isOn: $systemNotifications)
                Toggle("Use Apple Intelligence to summarize notifications", isOn: $summarizeWithAI)
                    .disabled(!aiSummarySupported)
                if aiSummarySupported {
                    Text("Generates a short description of each bell so bursts of notifications are distinguishable. On-device only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Requires macOS 26")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

// MARK: - Advanced

@Observable
private final class CLIInstallModel {
    enum State {
        case checking
        case installed
        case notInstalled
        case installing
        case uninstalling
        case failed(String)
    }

    var state: State = .checking

    private let installer = CLIInstaller()

    func checkInstalled() {
        state = installer.isInstalled() ? .installed : .notInstalled
    }

    func install() {
        state = .installing
        do {
            try installer.install()
            state = .installed
        } catch CLIInstallerError.cancelled {
            state = .notInstalled
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func uninstall() {
        state = .uninstalling
        do {
            try installer.uninstall()
            state = .notInstalled
        } catch CLIInstallerError.cancelled {
            state = .installed
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

private struct AdvancedSettingsView: View {
    @State private var cliModel = CLIInstallModel()

    var body: some View {
        Form {
            Section("Command-Line Tool") {
                CLIInstallRow(model: cliModel)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .onAppear {
            cliModel.checkInstalled()
        }
    }
}

private struct CLIInstallRow: View {
    @Bindable var model: CLIInstallModel

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("batty")
                Text("Symlinks `batty` to /usr/local/bin. Not required to run Batty.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .failed(let reason) = model.state {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            switch model.state {
            case .checking:
                ProgressView().controlSize(.small)
            case .notInstalled, .failed:
                Button("Install") {
                    model.install()
                }
            case .installed:
                Button("Uninstall", role: .destructive) {
                    model.uninstall()
                }
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .installing:
                ProgressView().controlSize(.small)
                Text("Installing\u{2026}").foregroundStyle(.secondary)
            case .uninstalling:
                ProgressView().controlSize(.small)
                Text("Uninstalling\u{2026}").foregroundStyle(.secondary)
            }
        }
    }
}
