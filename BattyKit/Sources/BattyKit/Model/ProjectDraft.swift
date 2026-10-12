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
    var layout: ProjectLayout
    var runStartupCommandsOnOpen: Bool
    /// Carried through untouched: editing commands never clears it, so
    /// reverting to the approved commands does not prompt again (#0473
    /// compares hashes at open time).
    var approvedCommandsHash: String?
    var lastOpenedAt: Date?
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
        layout = project.layout
        runStartupCommandsOnOpen = project.runStartupCommandsOnOpen
        approvedCommandsHash = project.approvedCommandsHash
        lastOpenedAt = project.lastOpenedAt
    }

    init(
        id: UUID = UUID(),
        name: String,
        rootPath: String,
        color: SessionColor,
        layout: ProjectLayout = .preset(.singlePane),
        runStartupCommandsOnOpen: Bool = true
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.color = color
        self.layout = layout
        self.runStartupCommandsOnOpen = runStartupCommandsOnOpen
        self.approvedCommandsHash = nil
        self.lastOpenedAt = nil
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
        let normalizedLayout = ProjectLayout(
            root: layout.root.mappingPanes { _, pane in
                var normalized = pane
                switch pane.kind {
                case .terminal:
                    let tabs = pane.tabs.map {
                        ProjectTab(
                            title: Self.trimmedOrNil($0.title),
                            workingDirectory: Self.normalizedRelativePath($0.workingDirectory),
                            startupCommand: Self.trimmedOrNil($0.startupCommand)
                        )
                    }
                    normalized.tabs = tabs.isEmpty ? [ProjectTab()] : tabs
                    normalized.repositoryPath = nil
                case .gitStatus:
                    normalized.tabs = []
                    let path = Self.normalizedRelativePath(pane.repositoryPath)
                    normalized.repositoryPath = path == "." ? nil : path
                case .processStatus, .systemMetrics, .lmStudioDashboard:
                    normalized.tabs = []
                    normalized.repositoryPath = nil
                }
                return normalized
            },
            preset: layout.preset
        )
        return Project(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            rootPath: Self.normalizedRoot(rootPath),
            color: color,
            layout: normalizedLayout,
            runStartupCommandsOnOpen: runStartupCommandsOnOpen,
            approvedCommandsHash: approvedCommandsHash,
            lastOpenedAt: lastOpenedAt
        )
    }
}
