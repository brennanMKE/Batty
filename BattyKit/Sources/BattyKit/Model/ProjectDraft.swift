// ProjectDraft.swift

import BattyXPCCore
import Foundation

/// The Project Editor's working copy. Free-form text is kept as typed
/// (blank titles, a `~` in the root, surrounding whitespace); `makeProject()`
/// is the single place it is normalized into a storable `Project`, and the
/// editor's dirty check compares normalized forms so typing a space and
/// deleting it is not a change.
struct ProjectDraft: Equatable {
    var id: UUID
    var name: String
    var rootPath: String
    var color: SessionColor
    /// `#RRGGBB` for a color outside the palette; `color` then holds the
    /// nearest palette entry.
    var customColorHex: String?
    var symbol: ProjectSymbol
    /// An SF Symbol outside the legacy set; `symbol` is then `.folder`.
    var customSymbolName: String?
    var layout: ProjectLayout
    var runStartupCommandsOnOpen: Bool
    /// Carried through untouched: editing commands never clears it, so
    /// reverting to the approved commands does not prompt again (#0473
    /// compares hashes at open time).
    var approvedCommandsHash: String?
    var lastOpenedAt: Date?
    /// Edited by the Sharing checkbox, and part of dirty tracking and Save.
    var isShared = false
    /// Carried through untouched; the store stamps it on save.
    var modifiedAt: Date?
    /// `nil` follows Settings. Edited by the Background row's sheet.
    var background: TerminalBackgroundSettings?
    /// Carried through; the store works out what a Save publishes.
    var sharedImage: ProjectSharedImage?
    /// `nil` follows Settings. Edited by the Theme row's sheet.
    var theme: ThemePair?
    /// Carried through; captured by Update Project, not edited here.
    var notificationsMuted = false
    var paneListExpanded = false
    /// Messages about parts of a captured Session that could not be kept as
    /// they were (a folder outside the root), shown as warnings until the
    /// field or the structure around it is edited. Not part of the Project.
    var captureNotes: [ProjectEditorField: String] = [:]
    /// The root is a placeholder because the captured Session had no known
    /// folder; the editor reports it as an error until the user sets one.
    var rootNeedsChoosing = false

    init(project: Project) {
        id = project.id
        name = project.name
        rootPath = project.rootPath
        color = project.color
        customColorHex = project.customColorHex
        symbol = project.symbol
        customSymbolName = project.customSymbolName
        layout = project.layout
        runStartupCommandsOnOpen = project.runStartupCommandsOnOpen
        approvedCommandsHash = project.approvedCommandsHash
        lastOpenedAt = project.lastOpenedAt
        isShared = project.isShared
        modifiedAt = project.modifiedAt
        background = project.background
        sharedImage = project.sharedImage
        theme = project.theme
        notificationsMuted = project.notificationsMuted
        paneListExpanded = project.paneListExpanded
    }

    init(
        id: UUID = UUID(),
        name: String,
        rootPath: String,
        color: SessionColor,
        symbol: ProjectSymbol = .folder,
        layout: ProjectLayout = .preset(.singlePane),
        runStartupCommandsOnOpen: Bool = true,
        customColorHex: String? = nil,
        customSymbolName: String? = nil,
        background: TerminalBackgroundSettings? = nil,
        theme: ThemePair? = nil
    ) {
        self.background = background
        self.theme = theme
        self.customColorHex = customColorHex
        self.customSymbolName = customSymbolName
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.color = color
        self.symbol = symbol
        self.layout = layout
        self.runStartupCommandsOnOpen = runStartupCommandsOnOpen
        self.approvedCommandsHash = nil
        self.lastOpenedAt = nil
    }

    /// True when the draft holds a startup command that would be stored but
    /// the run toggle is off. Counts commands as `makeProject()` stores them.
    var showsCommandsOffHint: Bool {
        !runStartupCommandsOnOpen && !makeProject().startupCommands.isEmpty
    }

    /// `~` expanded and the path standardized. Empty stays empty.
    static func normalizedRoot(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return Project.standardizedRoot((trimmed as NSString).expandingTildeInPath)
    }

    private static func trimmedOrNil(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func normalizedRelativePath(_ text: String?) -> String {
        trimmedOrNil(text) ?? "."
    }

    /// Terminal Panes keep their Tabs and no repository; Git Status keeps a
    /// repository and no Tabs; the other kinds keep neither. Tabs on a
    /// non-Terminal Pane would otherwise reach `Project.startupCommands` and
    /// the trust hash.
    func makeProject() -> Project {
        var normalizedLayout = layout
        normalizedLayout.root = layout.root.mappingPanes { _, pane in
                var normalized = pane
                switch pane.kind {
                case .terminal:
                    let tabs = pane.tabs.map {
                        ProjectTab(
                            title: Self.trimmedOrNil($0.title),
                            workingDirectory: Self.normalizedRelativePath($0.workingDirectory),
                            startupCommand: Self.trimmedOrNil($0.startupCommand),
                            background: $0.background,
                            image: $0.image
                        )
                    }
                    normalized.tabs = tabs.isEmpty ? [ProjectTab()] : tabs
                    normalized.repositoryPath = nil
                    if normalized.background == nil { normalized.image = nil }
                case .gitStatus:
                    normalized.tabs = []
                    let path = Self.normalizedRelativePath(pane.repositoryPath)
                    normalized.repositoryPath = path == "." ? nil : path
                    normalized.clearTerminalOnlyFields()
                case .processStatus, .systemMetrics, .lmStudioDashboard:
                    normalized.tabs = []
                    normalized.repositoryPath = nil
                    normalized.clearTerminalOnlyFields()
                }
                return normalized
            }
        return Project(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            rootPath: Self.normalizedRoot(rootPath),
            color: color,
            symbol: symbol,
            layout: normalizedLayout,
            runStartupCommandsOnOpen: runStartupCommandsOnOpen,
            approvedCommandsHash: approvedCommandsHash,
            lastOpenedAt: lastOpenedAt,
            isShared: isShared,
            modifiedAt: modifiedAt,
            customColorHex: customColorHex,
            customSymbolName: customSymbolName,
            background: background,
            sharedImage: sharedImage,
            theme: theme?.normalized,
            notificationsMuted: notificationsMuted,
            paneListExpanded: paneListExpanded
        )
    }
}

private extension ProjectPane {
    mutating func clearTerminalOnlyFields() {
        background = nil
        image = nil
        activeTab = nil
    }
}
