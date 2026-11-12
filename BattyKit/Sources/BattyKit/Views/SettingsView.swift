// SettingsView.swift

import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "SettingsView")

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

            AdvancedSettingsView(store: store)
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
    @State private var background = AppWideBackgroundEditor.Snapshot.off

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

            if let store {
                TerminalBackgroundSettingsSection(store: store, snapshot: $background)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        // On the Form, not the Section: a modifier on a Section can apply per
        // row, and rows can appear as they scroll in, so this could hash the
        // image more than once per appearance of Settings.
        .onAppear {
            guard let store else { return }
            background = AppWideBackgroundEditor(store: store).inspect()
        }
        // `background` is a local copy, refreshed only on appear, so without
        // this it would keep showing an image removed in the window.
        .onReceive(NotificationCenter.default.publisher(for: .battyBackgroundImagesDidChange)) { _ in
            guard let store else { return }
            background = AppWideBackgroundEditor(store: store).inspect()
        }
    }

    /// A per-appearance theme picker. `appliesNow` is true for the slot that
    /// matches the currently-displayed appearance — only that slot re-themes
    /// live surfaces on change. The off-appearance slot just persists; the
    /// `AppearanceObserver` applies it when the system switches to it.
    @ViewBuilder
    private func themePicker(_ label: String, selection: Binding<String>, appliesNow: Bool) -> some View {
        Picker(label, selection: selection) {
            Text("Default").tag("")
            ForEach(BattyThemeCatalog.allThemes, id: \.id) { theme in
                Text(theme.name).tag(theme.name)
            }
        }
        .pickerStyle(.menu)
        .onChange(of: selection.wrappedValue) { _, newValue in
            guard appliesNow, let store, !newValue.isEmpty,
                  let theme = BattyThemeCatalog.theme(named: newValue)
            else { return }
            store.applyThemeToAllSurfaces(theme)
        }
    }

    private func applyAppearance() {
        store?.applyAppearanceToAllSurfaces()
    }
}

/// The app-wide background's edits, apart from the view so they can be tested.
///
/// Inspecting hashes the image on the main actor, so only `inspect`, `pickImage`,
/// `removeImage` and `reset` do it. `update` runs on every slider event and
/// reuses the gate's memo.
@MainActor
struct AppWideBackgroundEditor {
    struct Snapshot: Equatable {
        var settings: TerminalBackgroundSettings
        var imageState: BackgroundImageState

        static let off = Snapshot(settings: .off, imageState: .none)
    }

    let store: AppStateStore

    private var gate: AppWideBackgroundGate { store.backgroundGate }

    var stored: TerminalBackgroundSettings { gate.storedSettings() }

    func inspect() -> Snapshot {
        let imageState = gate.refreshImageState()
        return Snapshot(settings: stored, imageState: imageState)
    }

    @discardableResult
    func update(_ transform: (TerminalBackgroundSettings) -> TerminalBackgroundSettings) -> TerminalBackgroundSettings {
        let current = stored
        let next = transform(current)
        guard next != current else { return current }
        SettingsPreference.writeBackground(next, defaults: gate.defaults)
        store.applyAppWideBackgroundToAllSurfaces()
        return next
    }

    /// Always inspects and pushes: repairing a damaged copy leaves the stored
    /// path unchanged, because the folder is named for the intact bytes.
    @discardableResult
    func pickImage(path: String) -> Snapshot {
        SettingsPreference.writeBackground(stored.pickingImage(path: path), defaults: gate.defaults)
        let snapshot = inspect()
        store.applyAppWideBackgroundToAllSurfaces()
        return snapshot
    }

    @discardableResult
    func removeImage() -> Snapshot {
        update { $0.withImagePath(nil) }
        return inspect()
    }

    @discardableResult
    func reset() -> Snapshot {
        SettingsPreference.clearBackground(defaults: gate.defaults)
        let snapshot = inspect()
        store.applyAppWideBackgroundToAllSurfaces()
        return snapshot
    }
}

/// Every write starts from a control binding, a button or the picker's choice,
/// through `AppWideBackgroundEditor`. There is deliberately no
/// `onChange` and no `@AppStorage` here. `snapshot` is a local copy owned by
/// the parent, refreshed when Settings appears and after each edit, and feeds
/// no AppKit call.
private struct TerminalBackgroundSettingsSection: View {
    let store: AppStateStore
    @Binding var snapshot: AppWideBackgroundEditor.Snapshot

    @State private var importError: String?
    @State private var importTask: Task<Void, Never>?

    private var editor: AppWideBackgroundEditor { AppWideBackgroundEditor(store: store) }

    private var message: String? {
        if let importError { return importError }
        switch snapshot.imageState {
        case .none, .usable: return nil
        case .missing: return String(localized: "Image not found. Choose it again.")
        case .rejected: return String(localized: "The saved image can't be used. Choose it again.")
        }
    }

    var body: some View {
        Section("Background") {
            TerminalBackgroundControls(
                current: snapshot.settings,
                isImporting: importTask != nil,
                message: message,
                identifierPrefix: "appearance-background",
                update: { transform in
                    snapshot.settings = editor.update(transform)
                },
                images: store.backgroundImages,
                onPickedLibraryImage: startAdopt(ofLibraryPath:),
                onRemoveImage: {
                    cancelImport()
                    snapshot = editor.removeImage()
                }
            )
            Text("Each Tab keeps its own copy of the image in memory. Image opacity is relative to terminal opacity.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Below 100%, the desktop and other windows show through, except in full screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Manage Images…") {
                    BackgroundImagesWindowController.shared.show(store: store)
                }
                .accessibilityIdentifier("appearance-background.manage-images")
                Button("Restore Defaults") {
                    cancelImport()
                    snapshot = editor.reset()
                }
                .accessibilityIdentifier("appearance-background.restore-defaults")
            }
        }
    }

    private func cancelImport() {
        importTask?.cancel()
        importTask = nil
        importError = nil
    }

    /// Not cancelled on disappear, so closing Settings doesn't lose the pick.
    private func startAdopt(ofLibraryPath libraryPath: String) {
        cancelImport()
        let importer = store.appWideBackgroundImageImporter
        let editor = editor
        let retaining = editor.stored.imagePath
        let sources = store.backgroundImages.pickSources
        importTask = Task {
            let adopted = await importer.adoptImage(path: libraryPath, from: sources, retaining: retaining)
            guard !Task.isCancelled else { return }
            if let adopted {
                snapshot = editor.pickImage(path: adopted)
            } else {
                importError = String(localized: "That image could not be read.")
            }
            importTask = nil
        }
    }
}

private struct NotificationsSettingsView: View {
    @Environment(\.appStateStore) private var store
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
                    .onChange(of: systemNotifications) { store?.systemNotificationsSettingChanged() }
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
        case installedElsewhere(String)
        case notInstalled
        case blockedByFile
        case installing
        case uninstalling
        case failed(String)
    }

    var state: State = .checking

    private let installer = CLIInstaller()

    /// `batty` for Prod, `batty-beta` for Beta (#0277) — drives every
    /// piece of UI copy that names the command, so it never hardcodes
    /// `batty` for a build that actually installs as something else.
    var commandName: String { installer.commandName }
    var installPath: String { installer.installPath }

    func checkInstalled() {
        state = Self.uiState(for: installer.inspectInstallState())
    }

    func install() {
        state = .installing
        do {
            try installer.install()
            state = .installed
        } catch CLIInstallerError.cancelled {
            checkInstalled()
        } catch CLIInstallerError.blockedByFile {
            state = .blockedByFile
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
            checkInstalled()
        } catch CLIInstallerError.blockedByFile {
            state = .blockedByFile
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private static func uiState(for installState: CLIInstaller.State) -> State {
        switch installState {
        case .installedHere: .installed
        case .installedElsewhere(let target): .installedElsewhere(target)
        case .notInstalled: .notInstalled
        case .blockedByFile: .blockedByFile
        }
    }
}

private struct AdvancedSettingsView: View {
    let store: AppStateStore?

    @State private var cliModel = CLIInstallModel()
    @State private var brokerModel = BrokerAgentController()

    var body: some View {
        Form {
            Section("Command-Line Tool") {
                CLIInstallRow(model: cliModel)
            }
            Section("Broker Agent") {
                if brokerModel.isEmbedded {
                    BrokerAgentRow(model: brokerModel, cliCommandName: cliModel.commandName)
                } else {
                    Text("Not available in this build.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Memory") {
                FootprintSoftLimitRow()
            }
            Section("Diagnostics") {
                BellDecisionExportRow(store: store)
                BellCaptureRow(store: store)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .onAppear {
            cliModel.checkInstalled()
            brokerModel.refresh()
        }
    }
}

/// #0297: exports `AppStateStore.bellDecisionHistory` — the in-memory
/// ring buffer of the most recent `BellDecisionHistory.capacity` bell/
/// notification decisions — so the user can find out what's generating
/// unwanted notifications. Nothing here is written anywhere until the user
/// presses Copy or Save; see `BellDecisionHistory`'s type doc comment for
/// why collection itself has no on/off toggle.
private struct BellDecisionExportRow: View {
    let store: AppStateStore?

    var body: some View {
        if let store {
            content(for: store.bellDecisionHistory)
        } else {
            Text("Not available.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func content(for history: BellDecisionHistory) -> some View {
        HStack {
            Text("\(history.records.count) of \(BellDecisionHistory.capacity) decisions collected")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Copy") {
                copyToPasteboard(history.records)
            }
            .disabled(history.records.isEmpty)
            Button("Save to File…") {
                saveToFile(history.records)
            }
            .disabled(history.records.isEmpty)
            Button("Clear", role: .destructive) {
                history.clear()
            }
            .disabled(history.records.isEmpty)
        }
        Text("Batty keeps the most recent \(BellDecisionHistory.capacity) bell and notification decisions in memory for this app session — which gate suppressed each one, or that it was submitted — so you can trace unwanted notifications back to their source. Session and tab titles and notification text are included as written. Nothing is written to disk until you choose Save; Copy places the same text on the system pasteboard, where every running app can read it and, with Handoff on, it can sync to your other devices. Clear (or quitting Batty) is the only way to drop what's collected so far.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func copyToPasteboard(_ records: [BellDecisionRecord]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(BellDecisionFormat.exportText(records), forType: .string)
    }

    /// Unlike `copyToPasteboard`, a write failure here is silent to the
    /// user by default — the panel just closes — so round-1 review's
    /// finding stands: this is the deliverable path (the whole feature is
    /// "get the data out"), and it needs its own error surface rather than
    /// `try?` swallowing whatever `Data.write` throws (permission denied,
    /// disk full, a volume that went away between panel and write).
    private func saveToFile(_ records: [BellDecisionRecord]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "batty-bell-decisions-\(Self.filenameTimestamp()).txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try BellDecisionFormat.exportText(records).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            logger.error("saveToFile failed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = String(localized: "Couldn't Save Bell Decisions")
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private static func filenameTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }
}

/// #0523: opt-in capture log of each Bell event's raw input and the text
/// Batty showed for it. Off by default; the file never leaves this Mac. File
/// existence is checked off the main thread (`BellCaptureWriter`'s queue).
private struct BellCaptureRow: View {
    let store: AppStateStore?

    @AppStorage(SettingsPreference.captureBellFeedDataKey)
    private var capture: Bool = SettingsPreference.defaultCaptureBellFeedData
    @State private var fileExists = false
    @State private var confirmingClear = false

    var body: some View {
        Toggle("Capture Bell Feed data", isOn: $capture)
            .accessibilityIdentifier("settings.bellCapture.toggle")
        Text("Records each bell and notification to a file on this Mac: the notification text, Tab and Session titles, working directory, and the AI summary exchange. Terminal output can contain secrets such as tokens, passwords and keys, so review the file before sharing it. The file stays on this Mac and is never sent anywhere. It keeps about the last 2,000 records.")
            .font(.caption)
            .foregroundStyle(.secondary)
        HStack {
            Button("Reveal Capture File in Finder") {
                if let url = store?.bellCaptureWriter?.currentFileURL {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            .disabled(!fileExists)
            Spacer()
            if confirmingClear {
                Text("Delete all captured records?")
                    .font(.caption)
                Button("Delete", role: .destructive) {
                    store?.clearBellCapture()
                    confirmingClear = false
                    Task { await refresh() }
                }
                Button("Cancel") { confirmingClear = false }
            } else {
                Button("Clear Capture", role: .destructive) { confirmingClear = true }
            }
        }
        .task { await refresh() }
        .onChange(of: capture) { _, _ in Task { await refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        guard let writer = store?.bellCaptureWriter else {
            fileExists = false
            return
        }
        fileExists = await writer.currentFileExists()
    }
}

private struct FootprintSoftLimitRow: View {
    @AppStorage(SettingsPreference.footprintSoftLimitGBKey)
    private var softLimitGB: Double = SettingsPreference.defaultFootprintSoftLimitGB

    var body: some View {
        Stepper(
            "Warn above \(Int(softLimitGB)) GB",
            value: $softLimitGB,
            in: 1...32,
            step: 1
        )
        Text("Batty checks its own memory footprint about once a minute. Crossing this limit posts a warning to the Bell Feed (and a system notification when Batty isn't frontmost) stating the footprint and how many Terminal Sessions are open.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct BrokerAgentRow: View {
    @Bindable var model: BrokerAgentController
    let cliCommandName: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("XPC broker")
                Text("Lets `\(cliCommandName)` reach Batty without launching it first. Registration state only — run `\(cliCommandName) ping` to confirm it actually answers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let lastErrorDescription = model.lastErrorDescription {
                    Text(lastErrorDescription)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            switch model.state {
            case .unknown, .notRegistered:
                Button("Register") {
                    model.register()
                }
            case .requiresApproval:
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Needs approval")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("System Settings → General → Login Items & Extensions")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button("Unregister", role: .destructive) {
                    model.unregister()
                }
            case .enabled:
                Button("Unregister", role: .destructive) {
                    model.unregister()
                }
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }
}

private struct CLIInstallRow: View {
    @Bindable var model: CLIInstallModel

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: model.commandName)
                Text("Symlinks `\(model.commandName)` to \(model.installPath). Not required to run Batty.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                switch model.state {
                case .failed(let reason):
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.red)
                case .blockedByFile:
                    Text("\(model.installPath) already exists and isn't a symlink Batty created. Remove it manually, then try installing again.")
                        .font(.caption)
                        .foregroundStyle(.red)
                case .installedElsewhere(let target):
                    Text("A stale link points to \(target). Installing will replace it.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                default:
                    EmptyView()
                }
            }
            Spacer()
            switch model.state {
            case .checking:
                ProgressView().controlSize(.small)
            case .notInstalled, .installedElsewhere, .blockedByFile, .failed:
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
