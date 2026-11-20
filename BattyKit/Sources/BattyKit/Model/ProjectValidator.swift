// ProjectValidator.swift

import Foundation

/// The Project rules shared by the Project Editor and the CLI's
/// `project create`/`edit`, so the two can't drift.
enum ProjectValidator {
    static func validate(
        _ project: Project,
        others: [Project],
        rootNeedsChoosing: Bool = false,
        directoryExists: (String) -> Bool,
        imageState: (String) -> BackgroundImageState,
        captureNotes: [ProjectEditorField: String] = [:]
    ) -> ProjectEditorValidation {
        var result = ProjectEditorValidation()

        if project.name.isEmpty {
            result.errors[.name] = String(localized: "Give the Project a name.", comment: "Project Editor validation")
        } else if let clash = others.first(where: {
            $0.id != project.id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == project.name.lowercased()
        }) {
            result.errors[.name] = String(localized: "Another Project is already named \u{201C}\(clash.name)\u{201D}.", comment: "Project Editor validation; names are unique ignoring case")
        }

        let rootIsUsable: Bool
        if rootNeedsChoosing {
            result.errors[.root] = String(localized: "Batty could not tell which folder this Session works in. Choose the Project's root folder.", comment: "Project Editor validation: a captured Session with no known folder")
            rootIsUsable = false
        } else if project.rootPath.isEmpty {
            result.errors[.root] = String(localized: "Choose the Project's root folder.", comment: "Project Editor validation")
            rootIsUsable = false
        } else if !project.rootPath.hasPrefix("/") {
            result.errors[.root] = String(localized: "The root folder must be an absolute path.", comment: "Project Editor validation")
            rootIsUsable = false
        } else if !directoryExists(project.rootPath) {
            result.errors[.root] = String(localized: "This folder does not exist.", comment: "Project Editor validation")
            rootIsUsable = false
        } else {
            rootIsUsable = true
        }

        for (slot, pane) in project.layout.panes.enumerated() {
            switch pane.kind {
            case .terminal:
                for (index, tab) in pane.tabs.enumerated() {
                    checkDirectory(
                        tab.workingDirectory, field: .tabDirectory(slot: slot, tab: index), project: project, rootIsUsable: rootIsUsable,
                        directoryExists: directoryExists,
                        missingFolderWarning: String(localized: "This folder does not exist yet; the Tab opens in the root folder instead.", comment: "Project Editor warning"),
                        into: &result)
                    if let command = tab.startupCommand, let problem = commandProblem(command) {
                        result.errors[.tabCommand(slot: slot, tab: index)] = problem
                    }
                    if let path = tab.background?.imagePath, let warning = imageWarning(imageState(path)) {
                        result.warnings[.tabBackground(slot: slot, tab: index)] = warning
                    }
                }
                if let path = pane.background?.imagePath, let warning = imageWarning(imageState(path)) {
                    result.warnings[.paneBackground(slot: slot)] = warning
                }
            case .gitStatus:
                checkDirectory(
                    pane.repositoryPath ?? ".", field: .repository(slot: slot), project: project, rootIsUsable: rootIsUsable,
                    directoryExists: directoryExists,
                    missingFolderWarning: String(localized: "This folder does not exist yet; the Git Status view will not find a repository there.", comment: "Project Editor warning"),
                    into: &result)
            case .processStatus, .systemMetrics, .lmStudioDashboard:
                break
            }
        }
        if let path = project.background?.imagePath, let warning = imageWarning(imageState(path)) {
            result.warnings[.background] = warning
        }
        if let name = unavailableThemeNames(project.theme).first {
            result.warnings[.theme] = String(localized: "“\(name)” isn't available in this version of Batty. Sessions opened from this Project use the Settings Theme instead until it is. Saving keeps it.", comment: "Project Editor: the Project names a Theme this Mac doesn't have; the argument is the name")
        }
        for (field, note) in captureNotes where result.errors[field] == nil && result.warnings[field] == nil {
            result.warnings[field] = note
        }
        return result
    }

    /// The Theme names in `theme` that this Mac's catalog doesn't have.
    static func unavailableThemeNames(_ theme: ThemePair?) -> [String] {
        guard let theme else { return [] }
        var names: [String] = []
        for name in [theme.dark, theme.light].compactMap({ $0 }) where BattyThemeCatalog.theme(named: name) == nil && !names.contains(name) {
            names.append(name)
        }
        return names
    }

    static func imageWarning(_ state: BackgroundImageState) -> String? {
        switch state {
        case .none, .usable:
            nil
        case .missing:
            String(localized: "Image not found. Choose it again.")
        case .rejected:
            String(localized: "The saved image can't be used. Choose it again.")
        }
    }

    private static func checkDirectory(
        _ relative: String,
        field: ProjectEditorField,
        project: Project,
        rootIsUsable: Bool,
        directoryExists: (String) -> Bool,
        missingFolderWarning: String,
        into result: inout ProjectEditorValidation
    ) {
        guard project.rootPath.hasPrefix("/") else { return }
        guard let url = project.resolve(relative) else {
            result.errors[field] = String(localized: "This path leaves the Project's root folder.", comment: "Project Editor validation")
            return
        }
        if rootIsUsable, !directoryExists(url.path) {
            result.warnings[field] = missingFolderWarning
        }
    }

    /// A command is delivered line by line with control and format
    /// characters dropped (`StartupCommandDelivery.lines(from:)`). Text that
    /// delivery would alter is refused here rather than run differently from
    /// what the user typed and approved.
    static func commandProblem(_ command: String) -> String? {
        let expected = command.components(separatedBy: .newlines).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if StartupCommandDelivery.lines(from: command) != expected {
            return String(localized: "This command contains control characters that cannot be typed into a shell.", comment: "Project Editor validation")
        }
        return nil
    }
}

extension ProjectEditorField {
    /// The field's name in CLI errors, as a path into the layout document.
    var cliPath: String {
        switch self {
        case .name: "name"
        case .root: "path"
        case .repository(let slot): "layout.panes[\(slot)].repository"
        case .tabDirectory(let slot, let tab): "layout.panes[\(slot)].tabs[\(tab)].cwd"
        case .tabCommand(let slot, let tab): "layout.panes[\(slot)].tabs[\(tab)].command"
        case .background: "background"
        case .tabBackground(let slot, let tab): "layout.panes[\(slot)].tabs[\(tab)].background"
        case .paneBackground(let slot): "layout.panes[\(slot)].background"
        case .theme: "theme"
        }
    }
}
