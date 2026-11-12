// ProjectEditorViewModel.swift

import BattyXPCCore
import Foundation
import Observation
import os
import SwiftUI

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "ProjectEditorViewModel")

/// Where a validation problem is shown, so the view can mark the field.
enum ProjectEditorField: Hashable {
    case name
    case root
    case repository(slot: Int)
    case tabDirectory(slot: Int, tab: Int)
    case tabCommand(slot: Int, tab: Int)
    case background
    case tabBackground(slot: Int, tab: Int)
    case theme
}

/// A move away from the current draft that the unsaved-changes question
/// guards.
enum ProjectEditorNavigation: Equatable {
    case select(UUID)
    case newProject
    case newDraft(ProjectDraft)
    case closeWindow
    /// The app is quitting. Perform replies to the pending quit request.
    case terminate
}

enum ProjectEditorUnsavedChoice: Sendable {
    case save, discard, cancel
}

enum ProjectCopyOutcome: Equatable {
    case applied
    /// The draft has Tabs, commands or views that the copy would replace.
    case needsConfirmation
    case noSession
}

enum ProjectPresetChange: Equatable {
    case applied
    /// Slots (zero-based) that carry configuration and would be dropped.
    case needsConfirmation(droppedSlots: [Int])
}

struct ProjectEditorValidation {
    var errors: [ProjectEditorField: String] = [:]
    var warnings: [ProjectEditorField: String] = [:]
    var isValid: Bool { errors.isEmpty }
}

struct ProjectEditorListEntry: Identifiable, Equatable {
    let id: UUID
    let name: String
    let path: String
    let color: SessionColor
    let symbol: ProjectSymbol
    let isUnsavedNew: Bool
    var isShared = false
    var customColorHex: String? = nil
    var customSymbolName: String? = nil

    var drawnColor: Color { ProjectAppearance.color(palette: color, customHex: customColorHex) }
    var systemName: String { ProjectAppearance.systemName(symbol: symbol, customName: customSymbolName) }
}

struct ProjectEditorTabSummary: Equatable {
    let title: String
    let line: String
}

/// The Project Editor's behavior, apart from any view: the draft, its
/// validation, and the only paths that write `ProjectStore`. Edits touch
/// only the draft; `save()` and `saveAndOpen()` (button actions) write the
/// store. Nothing here runs from `body`.
@MainActor
@Observable
final class ProjectEditorViewModel {
    static let untitledName = "Untitled Project"

    let store: ProjectStore

    @ObservationIgnored private let directoryExists: @MainActor (String) -> Bool
    @ObservationIgnored private let defaultRoot: @MainActor () -> String?
    @ObservationIgnored private let suggestName: @MainActor (String) -> String?
    /// Save & Open: starts the open once the editor is out of the way.
    @ObservationIgnored var openProject: @MainActor (UUID) -> Void
    /// Reads the content window's selected Session as a capture, made
    /// relative to the given root (nil derives one). Nil when there is no
    /// Session. Called only from a button action.
    @ObservationIgnored var captureSession: @MainActor (String?) -> SessionProjectCapture?
    /// Closes the editor window without asking.
    @ObservationIgnored var closeWindow: @MainActor () -> Void
    /// Called with the stored Project after every successful `save()`, so
    /// open Sessions can follow the symbol. Runs from the save action.
    @ObservationIgnored var projectSaved: @MainActor (Project) -> Void = { _ in }
    /// Brings the editor window front so a quit question is visible. False
    /// when the window cannot show one, for example because a sheet is
    /// already up on it.
    @ObservationIgnored var presentForQuit: @MainActor () -> Bool = { true }
    @ObservationIgnored private var quitReply: (@MainActor (Bool) -> Void)?
    /// `ProjectEditorWindowController` always passes one. Nil hides the
    /// Background row, and nothing here reads an image.
    @ObservationIgnored let backgrounds: ProjectBackgroundLibrary?
    /// What the Background sheet's picker shows. Passed with `backgrounds`.
    @ObservationIgnored let imageLibrary: BackgroundImagesModel?
    @ObservationIgnored private let appWideBackground: @MainActor () -> TerminalBackgroundSettings
    @ObservationIgnored private let sharedImagesMessage: @MainActor () -> String?
    /// False where nothing can fetch a waiting image: a routine Beta build reads
    /// the same `projects.json` as a signed one, and has no transport.
    @ObservationIgnored private let sharedImagesAvailable: Bool
    /// Names a Tab's image for another Mac. Nil names every image by digest.
    @ObservationIgnored let tabImageIdentity: TabImageIdentity?
    /// A stored Project was loaded for editing: the user action that may fetch
    /// its Tabs' images.
    @ObservationIgnored var projectLoaded: @MainActor (Project) -> Void

    private(set) var draft: ProjectDraft?
    private var baseline: Project?
    private(set) var selectedSlot = 0
    private(set) var saveError: String?
    private(set) var pendingNavigation: ProjectEditorNavigation?
    private(set) var pendingDeletion: UUID?
    /// Stored because `validate()` runs from `body`, which must not read files.
    /// Changes only when a Project loads or the draft's image path changes.
    private(set) var backgroundImageState: BackgroundImageState = .none
    /// Each Tab image's state, keyed by path, for the same reason as
    /// `backgroundImageState`.
    private(set) var tabImageStates: [String: BackgroundImageState] = [:]

    /// Panes the draft moved away from, per slot and kind, so Terminal to
    /// Git Status and back keeps the Tabs until Save. A preset change drops
    /// the entries of slots that no longer exist; `applyLayout`, loading a
    /// Project and Save clear it.
    @ObservationIgnored private var stash: [Int: [PaneContentKind: ProjectPane]] = [:]
    /// Stable identities for the Tabs of each slot, parallel to the draft's
    /// Tabs, so the inspector's rows keep their focus when an earlier Tab is
    /// removed. Missing entries fall back to a deterministic identity.
    @ObservationIgnored private var tabIdentities: [Int: [UUID]] = [:]
    /// A draft handed in by another feature (Save as Project) is not in the
    /// store, so closing or switching away from it asks first even before it
    /// is edited.
    private var isHandedInDraft = false
    @ObservationIgnored private var nameIsAutoSuggested = false

    init(
        store: ProjectStore,
        initialSelection: UUID? = nil,
        directoryExists: @escaping @MainActor (String) -> Bool = ProjectEditorViewModel.fileSystemDirectoryExists,
        defaultRoot: @escaping @MainActor () -> String? = { nil },
        suggestName: @escaping @MainActor (String) -> String? = ProjectEditorViewModel.suggestedName(forRoot:),
        openProject: @escaping @MainActor (UUID) -> Void = { _ in },
        captureSession: @escaping @MainActor (String?) -> SessionProjectCapture? = { _ in nil },
        closeWindow: @escaping @MainActor () -> Void = {},
        backgrounds: ProjectBackgroundLibrary? = nil,
        imageLibrary: BackgroundImagesModel? = nil,
        appWideBackground: @escaping @MainActor () -> TerminalBackgroundSettings = { .off },
        sharedImagesMessage: @escaping @MainActor () -> String? = { nil },
        sharedImagesAvailable: Bool = false,
        tabImageIdentity: TabImageIdentity? = nil,
        projectLoaded: @escaping @MainActor (Project) -> Void = { _ in }
    ) {
        self.tabImageIdentity = tabImageIdentity
        self.projectLoaded = projectLoaded
        self.sharedImagesMessage = sharedImagesMessage
        self.sharedImagesAvailable = sharedImagesAvailable
        self.backgrounds = backgrounds
        self.imageLibrary = imageLibrary
        self.appWideBackground = appWideBackground
        self.store = store
        self.directoryExists = directoryExists
        self.defaultRoot = defaultRoot
        self.suggestName = suggestName
        self.openProject = openProject
        self.captureSession = captureSession
        self.closeWindow = closeWindow
        if let project = initialSelection.flatMap({ store.project(id: $0) }) ?? store.projects.first {
            load(project)
        }
    }

    // MARK: - Defaults

    static func fileSystemDirectoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// `ProjectNameResolver` first, the folder's basename otherwise.
    static func suggestedName(forRoot path: String) -> String? {
        suggestedName(forRoot: path, homeDirectory: NSHomeDirectory())
    }

    /// Nil for the home folder and other non-project folders (`NonProjectDirectory`).
    static func suggestedName(forRoot path: String, homeDirectory: String) -> String? {
        if NonProjectDirectory.contains(path, home: homeDirectory) { return nil }
        if let resolved = ProjectNameResolver.shared.resolve(at: path), !resolved.isEmpty { return resolved }
        let base = URL(fileURLWithPath: path).lastPathComponent
        return base.isEmpty || base == "/" ? nil : base
    }

    // MARK: - Derived state

    var selectedID: UUID? { draft?.id }
    var isNewDraft: Bool { draft.map { store.project(id: $0.id) == nil } ?? false }

    var listEntries: [ProjectEditorListEntry] {
        var entries = store.projects.map {
            ProjectEditorListEntry(id: $0.id, name: $0.name, path: Self.abbreviated($0.rootPath), color: $0.color, symbol: $0.symbol, isUnsavedNew: false, isShared: $0.isShared, customColorHex: $0.customColorHex, customSymbolName: $0.customSymbolName)
        }
        if let draft, isNewDraft {
            let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(ProjectEditorListEntry(
                id: draft.id,
                name: name.isEmpty ? Self.untitledName : name,
                path: Self.abbreviated(ProjectDraft.normalizedRoot(draft.rootPath)),
                color: draft.color,
                symbol: draft.symbol,
                isUnsavedNew: true,
                isShared: draft.isShared,
                customColorHex: draft.customColorHex,
                customSymbolName: draft.customSymbolName
            ))
        }
        return entries
    }

    var isDirty: Bool {
        guard let draft, let baseline else { return false }
        return isHandedInDraft || draft.makeProject() != baseline
    }

    /// Each accessor below validates afresh; a view takes one `validate()`
    /// result per render and uses `canSave(_:)` / `canSaveAndOpen(_:)`.
    var validationIssues: [ProjectEditorField: String] { validate().errors }
    var validationWarnings: [ProjectEditorField: String] { validate().warnings }
    var isValid: Bool { draft != nil && validate().isValid }
    var canSave: Bool { canSave(validate()) }
    var canSaveAndOpen: Bool { canSaveAndOpen(validate()) }

    func canSave(_ validation: ProjectEditorValidation) -> Bool {
        draft != nil && validation.isValid && (isDirty || isNewDraft)
    }

    func canSaveAndOpen(_ validation: ProjectEditorValidation) -> Bool {
        draft != nil && validation.isValid
    }

    var slotCount: Int { draft?.layout.paneCount ?? 0 }
    var panes: [ProjectPane] { draft?.layout.panes ?? [] }
    var slotFrames: [CGRect] { draft?.layout.slotFrames ?? [] }
    var selectedPane: ProjectPane? { panes.indices.contains(selectedSlot) ? panes[selectedSlot] : nil }
    var selectedPosition: String {
        slotFrames.indices.contains(selectedSlot)
            ? ProjectLayoutGeometry.positionDescription(of: slotFrames[selectedSlot])
            : ""
    }

    /// One identity per Tab of the selected Pane, in order.
    var selectedTabIDs: [UUID] { tabIDs(slot: selectedSlot) }

    /// One identity per Tab of `slot`, in order.
    func tabIDs(slot: Int) -> [UUID] {
        let count = panes.indices.contains(slot) ? panes[slot].tabs.count : 0
        let known = tabIdentities[slot] ?? []
        return (0..<count).map { index in
            index < known.count ? known[index] : Self.fallbackTabID(slot: slot, index: index)
        }
    }

    private static func fallbackTabID(slot: Int, index: Int) -> UUID {
        UUID(uuid: (0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0, UInt8(truncatingIfNeeded: slot >> 8), UInt8(truncatingIfNeeded: slot),
                    UInt8(truncatingIfNeeded: index >> 8), UInt8(truncatingIfNeeded: index), 0, 0, 0, 1))
    }

    func tabSummaries(slot: Int) -> [ProjectEditorTabSummary] {
        guard panes.indices.contains(slot), panes[slot].kind == .terminal else { return [] }
        return panes[slot].tabs.enumerated().map { index, tab in
            let title = tab.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = tab.startupCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let directory = tab.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            let relative = directory.isEmpty || directory == "." ? "" : directory
            return ProjectEditorTabSummary(
                title: (title?.isEmpty == false ? title : nil) ?? String(localized: "Tab \(index + 1)", comment: "Project Editor: default name of an untitled Tab"),
                line: command.isEmpty
                    ? String(localized: "shell in root/\(relative)", comment: "Project Editor: a Tab with no startup command; the argument is the relative directory")
                    : "$ \(command)"
            )
        }
    }

    var showsBackground: Bool { backgrounds != nil && imageLibrary != nil }

    func appWideBackgroundValue() -> TerminalBackgroundSettings { appWideBackground() }

    var backgroundSummary: String {
        guard let background = draft?.background else {
            return String(localized: "Follows Settings", comment: "Project Editor: the Background row for a Project with no background of its own")
        }
        let image = background.imagePath.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
            ?? String(localized: "No image", comment: "Project Editor: the Background row for a Project that hides any image")
        let opacity = Int((background.terminalOpacity * 100).rounded())
        return String(localized: "Custom: \(image), terminal \(opacity)%", comment: "Project Editor: the Background row; the arguments are the image name and the terminal opacity")
    }

    func tabBackgroundSummary(slot: Int, index: Int) -> String {
        guard panes.indices.contains(slot), panes[slot].tabs.indices.contains(index),
              let background = panes[slot].tabs[index].background
        else {
            return String(localized: "Follows Project", comment: "Project Editor: a Tab's Background row with no background of its own")
        }
        let image = background.imagePath.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
            ?? String(localized: "No image", comment: "Project Editor: the Background row for a Project that hides any image")
        let opacity = Int((background.terminalOpacity * 100).rounded())
        return String(localized: "Custom: \(image), terminal \(opacity)%", comment: "Project Editor: the Background row; the arguments are the image name and the terminal opacity")
    }

    var themeSummary: String {
        guard let theme = draft?.theme, !theme.isEmpty else {
            return String(localized: "Follows Settings", comment: "Project Editor: the Theme row for a Project with no Theme of its own")
        }
        let follows = String(localized: "Follows Settings", comment: "Project Editor: a Theme slot with no Theme of its own")
        func display(_ name: String?) -> String {
            guard let name else { return follows }
            if BattyThemeCatalog.theme(named: name) == nil {
                return String(localized: "\(name) (not available)", comment: "Project Editor: a Theme name this Mac doesn't have; the argument is the name")
            }
            return name
        }
        if theme.dark == theme.light {
            return String(localized: "Dark and Light: \(display(theme.dark))", comment: "Project Editor: the Theme row when both appearances use one Theme")
        }
        return String(localized: "Dark: \(display(theme.dark)) · Light: \(display(theme.light))", comment: "Project Editor: the Theme row; the arguments are the Dark and Light Themes")
    }

    /// The draft's Theme names this Mac's catalog doesn't have.
    func unavailableThemeNames() -> [String] {
        guard let theme = draft?.theme else { return [] }
        var names: [String] = []
        for name in [theme.dark, theme.light].compactMap({ $0 }) where BattyThemeCatalog.theme(named: name) == nil && !names.contains(name) {
            names.append(name)
        }
        return names
    }

    /// Done in the Theme sheet. Guards equal values: `@Observable` notifies
    /// on every write.
    func setTheme(_ pair: ThemePair?) {
        let value = pair?.normalized
        guard draft != nil, draft?.theme != value else { return }
        draft?.theme = value
    }

    /// Set only while a Shared Project's image hasn't arrived on this Mac.
    var sharedImageCaption: String? {
        guard sharedImagesAvailable, draft?.isShared == true, case .named(let digest, let name)? = draft?.sharedImage,
              draft?.background?.imagePath.flatMap(TerminalBackgroundImageImporter.digest(ofPath:)) != digest
        else { return nil }
        return String(localized: "Waiting for \(name) from iCloud Drive.", comment: "Project Editor: a Shared Project's image hasn't arrived on this Mac yet; the argument is the image's name")
    }

    var sharedImageMessage: String? { sharedImagesMessage() }

    private func imageState(of background: TerminalBackgroundSettings?) -> BackgroundImageState {
        guard let backgrounds, let path = background?.imagePath else { return .none }
        return backgrounds.imageState(ofPath: path)
    }

    static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Validation

    func validate() -> ProjectEditorValidation {
        var result = ProjectEditorValidation()
        guard let draft else { return result }
        let project = draft.makeProject()

        if project.name.isEmpty {
            result.errors[.name] = String(localized: "Give the Project a name.", comment: "Project Editor validation")
        } else if let clash = store.projects.first(where: {
            $0.id != draft.id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == project.name.lowercased()
        }) {
            result.errors[.name] = String(localized: "Another Project is already named \u{201C}\(clash.name)\u{201D}.", comment: "Project Editor validation; names are unique ignoring case")
        }

        let rootIsUsable: Bool
        if draft.rootNeedsChoosing {
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
                        missingFolderWarning: String(localized: "This folder does not exist yet; the Tab opens in the root folder instead.", comment: "Project Editor warning"),
                        into: &result)
                    if let command = tab.startupCommand, let problem = Self.commandProblem(command) {
                        result.errors[.tabCommand(slot: slot, tab: index)] = problem
                    }
                    if let path = tab.background?.imagePath, let warning = Self.imageWarning(tabImageStates[path] ?? .none) {
                        result.warnings[.tabBackground(slot: slot, tab: index)] = warning
                    }
                }
            case .gitStatus:
                checkDirectory(
                    pane.repositoryPath ?? ".", field: .repository(slot: slot), project: project, rootIsUsable: rootIsUsable,
                    missingFolderWarning: String(localized: "This folder does not exist yet; the Git Status view will not find a repository there.", comment: "Project Editor warning"),
                    into: &result)
            case .processStatus, .systemMetrics, .lmStudioDashboard:
                break
            }
        }
        if let warning = Self.imageWarning(backgroundImageState) {
            result.warnings[.background] = warning
        }
        if let name = unavailableThemeNames().first {
            result.warnings[.theme] = String(localized: "“\(name)” isn't available in this version of Batty. Sessions opened from this Project use the Settings Theme instead until it is. Saving keeps it.", comment: "Project Editor: the Project names a Theme this Mac doesn't have; the argument is the name")
        }
        for (field, note) in draft.captureNotes where result.errors[field] == nil && result.warnings[field] == nil {
            result.warnings[field] = note
        }
        return result
    }

    private static func imageWarning(_ state: BackgroundImageState) -> String? {
        switch state {
        case .none, .usable:
            nil
        case .missing:
            String(localized: "Image not found. Choose it again.")
        case .rejected:
            String(localized: "The saved image can't be used. Choose it again.")
        }
    }

    private func checkDirectory(
        _ relative: String,
        field: ProjectEditorField,
        project: Project,
        rootIsUsable: Bool,
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

    // MARK: - Selection and navigation

    private func load(_ project: Project) {
        let loaded = ProjectDraft(project: project)
        draft = loaded
        baseline = loaded.makeProject()
        backgroundImageState = imageState(of: loaded.background)
        refreshTabImageStates(fresh: true)
        selectedSlot = 0
        stash = [:]
        tabIdentities = [:]
        isHandedInDraft = false
        nameIsAutoSuggested = false
        saveError = nil
        if !project.tabImages.isEmpty { projectLoaded(project) }
    }

    private func load(newDraft: ProjectDraft, handedIn: Bool = false, autoSuggestedName: Bool = false) {
        draft = newDraft
        baseline = newDraft.makeProject()
        backgroundImageState = imageState(of: newDraft.background)
        refreshTabImageStates(fresh: true)
        selectedSlot = 0
        stash = [:]
        tabIdentities = [:]
        isHandedInDraft = handedIn
        nameIsAutoSuggested = autoSuggestedName
        saveError = nil
    }

    /// Runs `navigation` now, or after the user answers the unsaved-changes
    /// question. Returns true when it ran immediately.
    @discardableResult
    func requestNavigation(_ navigation: ProjectEditorNavigation) -> Bool {
        if case .select(let id) = navigation, id == draft?.id { return true }
        if isDirty {
            if pendingNavigation == .terminate, navigation != .terminate { replyToQuit(false) }
            pendingNavigation = navigation
            return false
        }
        perform(navigation)
        return true
    }

    /// The app wants to quit. `reply(true)` lets it, `reply(false)` cancels
    /// it; it is called exactly once, at once when the draft is clean or the
    /// window cannot show the question, otherwise after the user answers the
    /// unsaved-changes question. A request that arrives while an earlier
    /// quit question is still up cancels both and dismisses the question.
    /// Discard replies true without touching the
    /// draft, so a quit cancelled later by another prompt loses nothing.
    func requestQuit(reply: @escaping @MainActor (Bool) -> Void) {
        replyToQuit(false)
        guard isDirty else {
            reply(true)
            return
        }
        if pendingNavigation == .terminate {
            abandonQuit()
            reply(false)
            return
        }
        guard presentForQuit() else {
            reply(false)
            return
        }
        quitReply = reply
        requestNavigation(.terminate)
    }

    /// Ends a pending quit question as cancelled, for a window that closes
    /// or a model that is replaced while one is up.
    func abandonQuit() {
        if pendingNavigation == .terminate { pendingNavigation = nil }
        replyToQuit(false)
    }

    private func replyToQuit(_ proceed: Bool) {
        guard let reply = quitReply else { return }
        quitReply = nil
        reply(proceed)
    }

    func requestSelect(_ id: UUID) { requestNavigation(.select(id)) }
    func requestNewProject() { requestNavigation(.newProject) }

    func resolveUnsaved(_ choice: ProjectEditorUnsavedChoice) {
        guard let navigation = pendingNavigation else { return }
        switch choice {
        case .cancel:
            pendingNavigation = nil
            if navigation == .terminate { replyToQuit(false) }
        case .discard:
            pendingNavigation = nil
            perform(navigation)
        case .save:
            guard save() != nil else {
                pendingNavigation = nil
                if navigation == .terminate { replyToQuit(false) }
                return
            }
            pendingNavigation = nil
            perform(navigation)
        }
    }

    private func perform(_ navigation: ProjectEditorNavigation) {
        switch navigation {
        case .select(let id):
            if let project = store.project(id: id) { load(project) }
        case .newProject:
            let made = makeNewDraftReportingSuggestion()
            load(newDraft: made.draft, autoSuggestedName: made.suggested)
        case .newDraft(let draft):
            load(newDraft: draft, handedIn: true)
        case .closeWindow:
            closeWindow()
        case .terminate:
            replyToQuit(true)
        }
    }

    func makeNewDraft() -> ProjectDraft {
        makeNewDraftReportingSuggestion().draft
    }

    /// `suggested` is true when the name came from the root folder rather
    /// than the untitled default, so choosing another folder may replace it.
    private func makeNewDraftReportingSuggestion() -> (draft: ProjectDraft, suggested: Bool) {
        let root: String = {
            if let provided = defaultRoot(), provided.hasPrefix("/") { return provided }
            return NSHomeDirectory()
        }()
        let suggested = suggestName(root)
        let taken = Set(store.projects.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let name: String
        var usedSuggestion = false
        if let suggested, !taken.contains(suggested.lowercased()) {
            name = suggested
            usedSuggestion = true
        } else {
            var candidate = Self.untitledName
            var counter = 2
            while taken.contains(candidate.lowercased()) {
                candidate = "\(Self.untitledName) \(counter)"
                counter += 1
            }
            name = candidate
        }
        let colors = SessionColor.allCases
        return (ProjectDraft(name: name, rootPath: root, color: colors[store.projects.count % colors.count]), usedSuggestion)
    }

    static func isUntitled(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return true }
        let base = untitledName.lowercased()
        if trimmed == base { return true }
        guard trimmed.hasPrefix(base + " ") else { return false }
        return Int(trimmed.dropFirst(base.count + 1)) != nil
    }

    // MARK: - Header edits

    func setName(_ name: String) {
        if name != draft?.name { nameIsAutoSuggested = false }
        draft?.name = name
        saveError = nil
    }

    func setRootPath(_ path: String) {
        draft?.rootPath = path
        draft?.rootNeedsChoosing = false
        draft?.captureNotes = [:]
        saveError = nil
    }

    /// The folder picked with Choose…. Pre-fills the name only when it is
    /// still empty or untitled.
    func applyChosenRoot(_ url: URL) {
        guard draft != nil else { return }
        let path = Project.standardizedRoot(url.path)
        draft?.rootPath = path
        draft?.rootNeedsChoosing = false
        draft?.captureNotes = [:]
        if let current = draft?.name, nameIsAutoSuggested || Self.isUntitled(current), let suggested = suggestName(path) {
            draft?.name = suggested
        }
        saveError = nil
    }

    /// A palette swatch. Clears any custom color.
    func setColor(_ color: SessionColor) {
        guard draft?.color != color || draft?.customColorHex != nil else { return }
        draft?.color = color
        draft?.customColorHex = nil
    }

    /// A color from the system color panel, as `#RRGGBB`. A value equal to a
    /// palette entry is stored as that entry. Ignores a malformed or
    /// unchanged value, because every write notifies observers.
    func setCustomColor(hex: String) {
        guard let draft, let normalized = ProjectAppearance.normalizedHex(hex) else { return }
        let resolved = ProjectAppearance.resolve(color: draft.color, customHex: normalized)
        guard resolved.color != draft.color || resolved.customHex != draft.customColorHex else { return }
        self.draft?.color = resolved.color
        self.draft?.customColorHex = resolved.customHex
    }

    /// A legacy symbol. Clears any custom symbol name.
    func setSymbol(_ symbol: ProjectSymbol) {
        guard draft?.symbol != symbol || draft?.customSymbolName != nil else { return }
        draft?.symbol = symbol
        draft?.customSymbolName = nil
    }

    /// Any SF Symbol name; one that matches a legacy symbol is stored as it.
    func setSymbolName(_ name: String) {
        guard let draft else { return }
        let resolved = ProjectAppearance.resolve(symbol: draft.symbol, customName: name)
        guard resolved.symbol != draft.symbol || resolved.customName != draft.customSymbolName else { return }
        self.draft?.symbol = resolved.symbol
        self.draft?.customSymbolName = resolved.customName
    }
    func setRunStartupCommandsOnOpen(_ value: Bool) { draft?.runStartupCommandsOnOpen = value }
    func setShared(_ value: Bool) { draft?.isShared = value }

    // MARK: - Layout

    func selectSlot(_ slot: Int) {
        guard slot != selectedSlot, panes.indices.contains(slot) else { return }
        selectedSlot = slot
    }

    func moveSelection(_ direction: ProjectPaneDirection) {
        if let next = ProjectLayoutGeometry.neighbor(of: selectedSlot, in: slotFrames, toward: direction) {
            selectedSlot = next
        }
    }

    static func hasConfiguration(_ pane: ProjectPane) -> Bool {
        switch pane.kind {
        case .terminal:
            if pane.tabs.count > 1 { return true }
            return pane.tabs.contains {
                $0.background != nil
                    || !($0.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    || !($0.startupCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    || !["", "."].contains($0.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        case .gitStatus:
            return !["", "."].contains((pane.repositoryPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        case .processStatus, .systemMetrics, .lmStudioDashboard:
            return true
        }
    }

    /// Slot `i` keeps its configuration when it still exists. Slots that
    /// would go away and carry configuration need `confirmDrop`.
    @discardableResult
    func changePreset(to preset: PaneLayout, confirmDrop: Bool = false) -> ProjectPresetChange {
        guard let draft else { return .applied }
        if draft.layout.preset == preset { return .applied }
        let current = draft.layout.panes
        let newCount = preset.paneCount
        let dropped = current.indices.filter { $0 >= newCount && Self.hasConfiguration(current[$0]) }
        if !dropped.isEmpty && !confirmDrop { return .needsConfirmation(droppedSlots: dropped) }

        let kept = Array(current.prefix(newCount))
        var layout = ProjectLayout.preset(preset, kinds: kept.map(\.kind))
        layout.root = layout.root.withPanes(kept)
        self.draft?.layout = layout
        self.draft?.captureNotes = [:]
        stash = stash.filter { $0.key < newCount }
        tabIdentities = [:]
        selectedSlot = min(selectedSlot, newCount - 1)
        return .applied
    }

    /// For #0476's "Copy from current Session": takes a captured topology
    /// as the draft's layout. Every slot's configuration comes from
    /// `layout`; the preset highlight follows `layout.preset`.
    func applyLayout(_ layout: ProjectLayout) {
        guard draft != nil else { return }
        draft?.layout = layout
        draft?.captureNotes = [:]
        stash = [:]
        tabIdentities = [:]
        selectedSlot = min(selectedSlot, max(layout.paneCount - 1, 0))
    }

    /// "Copy from current Session": replaces the draft's layout, Pane kinds
    /// and Tabs with a capture of the content window's selected Session,
    /// made relative to the draft's root. Name, color, the run toggle and the
    /// background stay.
    /// Asks first (`.needsConfirmation`) when that would discard configured
    /// Tabs, commands or views. An empty root takes the Session's folder.
    @discardableResult
    func copyFromCurrentSession(confirmDiscard: Bool = false) -> ProjectCopyOutcome {
        guard let current = draft else { return .noSession }
        let root = ProjectDraft.normalizedRoot(current.rootPath)
        guard let capture = captureSession(root.hasPrefix("/") ? root : nil) else {
            saveError = String(localized: "There is no Session to copy from.", comment: "Project Editor: Copy from current Session with no Session open")
            return .noSession
        }
        if !confirmDiscard, current.layout.panes.contains(where: Self.hasConfiguration) {
            return .needsConfirmation
        }
        saveError = nil
        applyLayout(capture.layout)
        draft?.captureNotes = capture.notes
        if !root.hasPrefix("/") {
            draft?.rootPath = capture.rootPath
            draft?.rootNeedsChoosing = capture.rootIsFallback
        }
        return .applied
    }

    private func updateSelectedPane(_ transform: (inout ProjectPane) -> Void) {
        guard let current = draft, current.layout.panes.indices.contains(selectedSlot) else { return }
        let slot = selectedSlot
        let root = current.layout.root.mappingPanes { index, pane in
            guard index == slot else { return pane }
            var edited = pane
            transform(&edited)
            return edited
        }
        draft?.layout.root = root
    }

    /// Terminal to Git Status and back keeps the Terminal Tabs: the draft
    /// remembers the Pane it left behind for this slot and kind until Save.
    func setKind(_ kind: PaneContentKind) {
        guard let pane = selectedPane, pane.kind != kind else { return }
        let slot = selectedSlot
        tabIdentities[slot] = nil
        draft?.captureNotes = [:]
        stash[slot, default: [:]][pane.kind] = pane
        let replacement = stash[slot]?[kind] ?? (kind == .terminal ? .terminal() : ProjectPane(kind: kind))
        updateSelectedPane { $0 = replacement }
    }

    func addTab() {
        guard selectedPane?.kind == .terminal else { return }
        var ids = selectedTabIDs
        ids.append(UUID())
        tabIdentities[selectedSlot] = ids
        updateSelectedPane { $0.tabs.append(ProjectTab()) }
    }

    func removeTab(at index: Int) {
        guard let pane = selectedPane, pane.kind == .terminal, pane.tabs.count > 1, pane.tabs.indices.contains(index) else { return }
        var ids = selectedTabIDs
        ids.remove(at: index)
        tabIdentities[selectedSlot] = ids
        draft?.captureNotes = [:]
        updateSelectedPane { $0.tabs.remove(at: index) }
    }

    func setTabTitle(_ index: Int, _ title: String) { updateTab(index) { $0.title = title } }
    func setTabDirectory(_ index: Int, _ path: String) {
        draft?.captureNotes[.tabDirectory(slot: selectedSlot, tab: index)] = nil
        updateTab(index) { $0.workingDirectory = path }
    }
    func setTabCommand(_ index: Int, _ command: String) { updateTab(index) { $0.startupCommand = command } }

    private func updateTab(_ index: Int, _ transform: (inout ProjectTab) -> Void) {
        updateSelectedPane { pane in
            guard pane.kind == .terminal, pane.tabs.indices.contains(index) else { return }
            transform(&pane.tabs[index])
        }
    }

    func setRepositoryPath(_ path: String) {
        draft?.captureNotes[.repository(slot: selectedSlot)] = nil
        updateSelectedPane { pane in
            guard pane.kind == .gitStatus else { return }
            pane.repositoryPath = path
        }
    }

    /// The path of `url` relative to the draft's root, or nil when it lies
    /// outside the root. "." for the root itself.
    func relativePath(of url: URL) -> String? {
        guard let draft else { return nil }
        let typedRoot = ProjectDraft.normalizedRoot(draft.rootPath)
        guard typedRoot.hasPrefix("/") else { return nil }
        let root = URL(fileURLWithPath: typedRoot).resolvingSymlinksInPath().path
        let target = url.resolvingSymlinksInPath().path
        if target == root { return "." }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard target.hasPrefix(prefix) else { return nil }
        return String(target.dropFirst(prefix.count))
    }

    /// The folder chooser for a Tab or repository is limited to the root.
    /// Returns false, and says why, for a folder outside it.
    @discardableResult
    func applyChosenDirectory(_ url: URL, tab: Int?) -> Bool {
        guard let relative = relativePath(of: url) else {
            saveError = String(localized: "Choose a folder inside the Project's root folder.", comment: "Project Editor: a folder chooser result outside the root")
            return false
        }
        saveError = nil
        if let tab { setTabDirectory(tab, relative) } else { setRepositoryPath(relative) }
        return true
    }

    // MARK: - Save, open, cancel, delete

    /// Writes exactly the edited Project to the store. Nil, with
    /// `saveError` or the field messages showing why, when it did not.
    @discardableResult
    func save() -> Project? {
        guard let draft else { return nil }
        guard validationIssues.isEmpty else {
            saveError = String(localized: "Fix the highlighted fields before saving.", comment: "Project Editor")
            return nil
        }
        if !isDirty, !isNewDraft, let unchanged = store.project(id: draft.id) {
            saveError = nil
            return unchanged
        }
        var project = draft.makeProject()
        if let current = store.project(id: draft.id) {
            project.approvedCommandsHash = current.approvedCommandsHash
            project.lastOpenedAt = current.lastOpenedAt
            if draft.isShared == baseline?.isShared { project.isShared = current.isShared }
        }
        do {
            try store.upsert(project)
        } catch let error as ProjectStoreError {
            saveError = Self.message(for: error)
            return nil
        } catch let error as ProjectSyncError {
            saveError = error.localizedDescription
            return nil
        } catch {
            logger.error("project save failed: \(error.localizedDescription, privacy: .public)")
            saveError = String(localized: "Could not save the Project: \(error.localizedDescription)", comment: "Project Editor")
            return nil
        }
        let stored = store.project(id: project.id) ?? project
        let slot = selectedSlot
        load(stored)
        selectedSlot = min(slot, max(stored.layout.paneCount - 1, 0))
        projectSaved(stored)
        return stored
    }

    /// Saves, closes the editor, then opens through `openProject`. The
    /// editor closes first so the trust sheet presents over a content
    /// window, not behind this one.
    @discardableResult
    func saveAndOpen() -> Bool {
        guard let project = save() else { return false }
        closeWindow()
        openProject(project.id)
        return true
    }

    /// Cancel: nothing is written, and the editor closes.
    func cancel() {
        if let id = draft?.id, let project = store.project(id: id) {
            load(project)
        } else {
            draft = nil
            baseline = nil
        }
        closeWindow()
    }

    func requestDelete(_ id: UUID) {
        if id == draft?.id, isNewDraft {
            discardNewDraft()
        } else if store.project(id: id) != nil {
            pendingDeletion = id
        }
    }

    func cancelDeletion() { pendingDeletion = nil }

    func confirmDeletion() {
        guard let id = pendingDeletion else { return }
        pendingDeletion = nil
        let wasSelected = draft?.id == id
        let index = store.projects.firstIndex { $0.id == id }
        do {
            try store.delete(id: id)
        } catch {
            logger.error("project delete failed: \(error.localizedDescription, privacy: .public)")
            saveError = String(localized: "Could not delete the Project: \(error.localizedDescription)", comment: "Project Editor")
            return
        }
        guard wasSelected else { return }
        let projects = store.projects
        if let index, let next = projects.indices.contains(index) ? projects[index] : projects.last {
            load(next)
        } else {
            draft = nil
            baseline = nil
        }
    }

    private func discardNewDraft() {
        if let last = store.projects.last { load(last) } else {
            draft = nil
            baseline = nil
        }
    }

    func moveProjects(from source: IndexSet, to destination: Int) {
        var ids = store.projects.map(\.id)
        let movable = IndexSet(source.filter { ids.indices.contains($0) })
        guard !movable.isEmpty else { return }
        ids.move(fromOffsets: movable, toOffset: min(destination, ids.count))
        do {
            try store.reorder(ids)
        } catch {
            logger.error("project reorder failed: \(error.localizedDescription, privacy: .public)")
            saveError = String(localized: "Could not reorder Projects: \(error.localizedDescription)", comment: "Project Editor")
        }
    }

    /// Moves a stored Project one place up (`-1`) or down (`+1`), for the
    /// context menu; dragging is the other way to reorder.
    func moveProject(_ id: UUID, by offset: Int) {
        guard let index = store.projects.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard store.projects.indices.contains(target) else { return }
        moveProjects(from: IndexSet(integer: index), to: offset > 0 ? target + 1 : target)
    }

    func canMoveProject(_ id: UUID, by offset: Int) -> Bool {
        guard let index = store.projects.firstIndex(where: { $0.id == id }) else { return false }
        return store.projects.indices.contains(index + offset)
    }

    var unreadableFilePath: String? { store.unreadableFilePath }

    static func message(for error: ProjectStoreError) -> String {
        switch error {
        case .emptyName:
            String(localized: "Give the Project a name.", comment: "Project Editor validation")
        case .duplicateName(let name):
            String(localized: "Another Project is already named \u{201C}\(name)\u{201D}.", comment: "Project Editor validation; names are unique ignoring case")
        case .applicationSupportUnavailable, .noFileURL:
            String(localized: "Projects cannot be saved because their storage location is unavailable.", comment: "Project Editor")
        case .unknownProject:
            String(localized: "That Project no longer exists.", comment: "Project Editor")
        case .fileUnreadable(let path):
            String(localized: "Batty can't read your saved Projects, so this wasn't saved and they haven't been changed. Check that Batty can read \(path), then try again.", comment: "Project Editor: a save refused because projects.json can't be read")
        }
    }
}

extension ProjectEditorViewModel {
    /// Reads files, so it runs only when a Project loads or a Tab path changes.
    /// `fresh` reads every path again, as a load must.
    func refreshTabImageStates(fresh: Bool = false) {
        let paths = Set(draft?.makeProject().tabBackgroundImagePaths ?? [])
        var states: [String: BackgroundImageState] = [:]
        for path in paths {
            states[path] = (fresh ? nil : tabImageStates[path]) ?? backgrounds.map { $0.imageState(ofPath: path) } ?? BackgroundImageState.none
        }
        guard states != tabImageStates else { return }
        tabImageStates = states
    }

    private func tabIndex(slot: Int, tabID: UUID) -> Int? {
        tabIDs(slot: slot).firstIndex(of: tabID)
    }

    func tabBackground(slot: Int, tabID: UUID) -> TerminalBackgroundSettings? {
        guard let index = tabIndex(slot: slot, tabID: tabID) else { return nil }
        return panes[slot].tabs[index].background
    }

    /// Writes nothing when the Tab has been removed since the sheet opened. A
    /// newly chosen path is copied into the Project folder, as the Project's is.
    func setTabBackground(slot: Int, tabID: UUID, _ newValue: TerminalBackgroundSettings?) {
        guard let current = draft, let index = tabIndex(slot: slot, tabID: tabID),
              panes[slot].kind == .terminal
        else { return }
        let field = ProjectEditorField.tabBackground(slot: slot, tab: index)
        let existing = panes[slot].tabs[index].background
        var value = newValue
        var adoptFailed = false
        if let backgrounds, let path = value?.imagePath, path != existing?.imagePath,
           !(baseline?.allBackgroundImagePaths.contains(path) ?? false) {
            let adopted = backgrounds.adopt(path: path)
            adoptFailed = adopted == nil
            value = value?.withImagePath(adopted)
        }
        let note = adoptFailed
            ? String(localized: "That image could not be copied, so this Tab has no image. Choose it again.", comment: "Project Editor: a Tab background image could not be copied into the Project")
            : nil
        let existingImage = panes[slot].tabs[index].image
        let image: ProjectTabImage? = if value == nil {
            nil
        } else if value?.imagePath == existing?.imagePath {
            existingImage
        } else {
            Self.tabImage(forPath: value?.imagePath, keeping: existingImage, previousPath: existing?.imagePath, identity: tabImageIdentity)
        }
        guard value != existing || image != existingImage || note != current.captureNotes[field] else { return }
        if value != existing || image != existingImage {
            draft?.layout.root = current.layout.root.mappingPanes { paneSlot, pane in
                guard paneSlot == slot, pane.tabs.indices.contains(index) else { return pane }
                var edited = pane
                edited.tabs[index].background = value
                edited.tabs[index].image = image
                return edited
            }
        }
        if note != current.captureNotes[field] { draft?.captureNotes[field] = note }
        if value?.imagePath != existing?.imagePath { refreshTabImageStates() }
    }

    /// Without an identity source, an image is named by its digest.
    static func tabImage(forPath path: String?, keeping: ProjectTabImage?, previousPath: String?, identity: TabImageIdentity?) -> ProjectTabImage? {
        if let identity { return identity.identity(forPath: path, keeping: keeping, previousPath: previousPath) }
        guard let path else { return nil }
        if let keeping, let previousPath, TerminalBackgroundImageImporter.digest(ofPath: previousPath) == TerminalBackgroundImageImporter.digest(ofPath: path) {
            return keeping
        }
        return ProjectTabImage.derive(path: path, hostedRecords: [], cacheEntries: [])
    }

    func projectTabBackgroundTarget(slot: Int, tabID: UUID) -> ProjectTabBackgroundTarget {
        ProjectTabBackgroundTarget(model: self, slot: slot, tabID: tabID)
    }
}

/// The sheet's target for one Tab of the draft. Holds no state of its own, so
/// building one in `body` writes nothing.
@MainActor
final class ProjectTabBackgroundTarget: BackgroundOverrideHolder {
    weak var model: ProjectEditorViewModel?
    let slot: Int
    let tabID: UUID

    init(model: ProjectEditorViewModel, slot: Int, tabID: UUID) {
        self.model = model
        self.slot = slot
        self.tabID = tabID
    }

    var backgroundOverride: TerminalBackgroundSettings? { model?.tabBackground(slot: slot, tabID: tabID) }

    func setBackgroundOverride(_ newOverride: TerminalBackgroundSettings?) {
        model?.setTabBackground(slot: slot, tabID: tabID, newOverride)
    }

    func inheritedBackground(appWide: TerminalBackgroundSettings) -> TerminalBackgroundSettings {
        model?.draft?.background ?? appWide
    }

    func isSavedImagePath(_ path: String) -> Bool { model?.isSavedImagePath(path) ?? false }
}

extension ProjectEditorViewModel: BackgroundOverrideHolder {
    var backgroundOverride: TerminalBackgroundSettings? { draft?.background }

    /// A newly chosen path is copied into the Project folder, because the sheet
    /// seeds Custom from the app-wide value, whose copy the app-wide cleanup can
    /// delete. The baseline's own path stays as it is, so Cancel over a bad
    /// stored path leaves the draft clean. A slider edit keeps the path, so it
    /// reads no file.
    func setBackgroundOverride(_ newOverride: TerminalBackgroundSettings?) {
        guard let current = draft else { return }
        var value = newOverride
        var adoptFailed = false
        if let backgrounds, let path = value?.imagePath,
           path != current.background?.imagePath, path != baseline?.background?.imagePath {
            let adopted = backgrounds.adopt(path: path)
            adoptFailed = adopted == nil
            value = value?.withImagePath(adopted)
        }
        let note = adoptFailed
            ? String(localized: "That image could not be copied, so this Project has no image. Choose it again.", comment: "Project Editor: a background image could not be copied into the Project")
            : nil
        guard value != current.background || note != current.captureNotes[.background] else { return }
        if value != current.background { draft?.background = value }
        if note != current.captureNotes[.background] { draft?.captureNotes[.background] = note }
        if value?.imagePath != current.background?.imagePath {
            backgroundImageState = imageState(of: value)
        }
    }

    func inheritedBackground(appWide: TerminalBackgroundSettings) -> TerminalBackgroundSettings {
        appWide
    }

    func isSavedImagePath(_ path: String) -> Bool {
        baseline?.allBackgroundImagePaths.contains(path) ?? false
    }

    /// The store has already cleared the saved Project, so the baseline follows
    /// it and a clean editor stays clean. If only the draft named the image,
    /// the user's edit is what changed, so it gets a note.
    func backgroundImageWasRemoved(digest: String) {
        func names(_ settings: TerminalBackgroundSettings?) -> Bool {
            settings?.imagePath.flatMap(TerminalBackgroundImageImporter.digest(ofPath:)) == digest
        }
        let baselineNamed = names(baseline?.background)
        let draftNamed = names(draft?.background)
        if baselineNamed {
            let cleared = baseline?.background?.withImagePath(nil)
            baseline?.background = cleared
        }
        tabBackgroundImageWasRemoved(names: names)
        guard draftNamed else { return }
        let cleared = draft?.background?.withImagePath(nil)
        draft?.background = cleared
        backgroundImageState = .none
        if !baselineNamed {
            draft?.captureNotes[.background] = String(localized: "The image you chose was removed, so this Project has no image.", comment: "Project Editor: the draft's background image was removed in the Background Images window")
        }
    }

    private func tabBackgroundImageWasRemoved(names: (TerminalBackgroundSettings?) -> Bool) {
        func clear(_ settings: TerminalBackgroundSettings) -> TerminalBackgroundSettings? {
            names(settings) ? settings.withImagePath(nil) : settings
        }
        if let baseline, baseline.tabBackgroundImagePaths.contains(where: { names(TerminalBackgroundSettings(imagePath: $0)) }) {
            self.baseline?.layout = baseline.layout.mappingTabBackgrounds(clear)
        }
        guard let draft, draft.layout.panes.flatMap(\.tabs).contains(where: { names($0.background) }) else { return }
        let baselineTabs = self.baseline?.layout.panes.map(\.tabs) ?? []
        var notes: [ProjectEditorField] = []
        let root = draft.layout.root.mappingPanes { slot, pane in
            var edited = pane
            for index in pane.tabs.indices where names(pane.tabs[index].background) {
                edited.tabs[index].background = pane.tabs[index].background?.withImagePath(nil)
                let stored = baselineTabs.indices.contains(slot) && baselineTabs[slot].indices.contains(index) ? baselineTabs[slot][index].background : nil
                if stored != edited.tabs[index].background { notes.append(.tabBackground(slot: slot, tab: index)) }
            }
            return edited
        }
        self.draft?.layout.root = root
        for field in notes {
            self.draft?.captureNotes[field] = String(localized: "The image you chose was removed, so this Tab has no image.", comment: "Project Editor: a Tab's background image was removed in the Background Images window")
        }
        refreshTabImageStates()
    }

    /// A Tab image was found or arrived. The baseline follows the store and a
    /// clean editor stays clean; a draft Tab still waiting for it gets it.
    func tabImageArrived(projectID: UUID, identity: ProjectTabImage, path: String) {
        guard let draft, draft.id == projectID, let baseline, baseline.id == projectID else { return }
        func apply(_ layout: ProjectLayout) -> ProjectLayout {
            layout.mappingTabs { tab in
                guard tab.image == identity, let background = tab.background, background.imagePath == nil else { return tab }
                var tab = tab
                tab.background = background.withImagePath(path)
                return tab
            }
        }
        let newBaseline = apply(baseline.layout)
        if newBaseline != baseline.layout { self.baseline?.layout = newBaseline }
        let newDraft = apply(draft.layout)
        guard newDraft != draft.layout else { return }
        self.draft?.layout = newDraft
        refreshTabImageStates()
    }

    /// The user doesn't want the waiting image. Any earlier image goes with it,
    /// because a Save would otherwise publish that one instead of a removal.
    func declineSharedImage() {
        guard let background = draft?.background else { return }
        draft?.sharedImage = nil
        draft?.background = background.withImagePath(nil)
        backgroundImageState = .none
    }

    /// The store has already recorded the path, so the baseline follows it and a
    /// clean editor stays clean. A draft whose background the user has edited
    /// keeps its image.
    func sharedImageArrived(projectID: UUID, path: String) {
        guard let draft, draft.id == projectID, let baseline, baseline.id == projectID else { return }
        let earlier = baseline.background?.imagePath
        self.baseline?.background = baseline.background?.withImagePath(path)
        guard draft.background?.imagePath == earlier, draft.sharedImage == baseline.sharedImage,
              let background = draft.background
        else { return }
        self.draft?.background = background.withImagePath(path)
        backgroundImageState = imageState(of: self.draft?.background)
    }
}
