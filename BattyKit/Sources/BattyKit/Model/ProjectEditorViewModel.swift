// ProjectEditorViewModel.swift

import BattyXPCCore
import Foundation
import Observation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "ProjectEditorViewModel")

/// Where a validation problem is shown, so the view can mark the field.
enum ProjectEditorField: Hashable {
    case name
    case root
    case repository(slot: Int)
    case tabDirectory(slot: Int, tab: Int)
    case tabCommand(slot: Int, tab: Int)
}

/// A move away from the current draft that the unsaved-changes question
/// guards.
enum ProjectEditorNavigation: Equatable {
    case select(UUID)
    case newProject
    case newDraft(ProjectDraft)
    case closeWindow
}

enum ProjectEditorUnsavedChoice: Sendable {
    case save, discard, cancel
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
    let isUnsavedNew: Bool
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
    /// Closes the editor window without asking.
    @ObservationIgnored var closeWindow: @MainActor () -> Void

    private(set) var draft: ProjectDraft?
    private var baseline: Project?
    private(set) var selectedSlot = 0
    private(set) var saveError: String?
    private(set) var pendingNavigation: ProjectEditorNavigation?
    private(set) var pendingDeletion: UUID?

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
        closeWindow: @escaping @MainActor () -> Void = {}
    ) {
        self.store = store
        self.directoryExists = directoryExists
        self.defaultRoot = defaultRoot
        self.suggestName = suggestName
        self.openProject = openProject
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
        if let resolved = ProjectNameResolver.shared.resolve(at: path), !resolved.isEmpty { return resolved }
        let base = URL(fileURLWithPath: path).lastPathComponent
        return base.isEmpty || base == "/" ? nil : base
    }

    // MARK: - Derived state

    var selectedID: UUID? { draft?.id }
    var isNewDraft: Bool { draft.map { store.project(id: $0.id) == nil } ?? false }

    var listEntries: [ProjectEditorListEntry] {
        var entries = store.projects.map {
            ProjectEditorListEntry(id: $0.id, name: $0.name, path: Self.abbreviated($0.rootPath), color: $0.color, isUnsavedNew: false)
        }
        if let draft, isNewDraft {
            let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(ProjectEditorListEntry(
                id: draft.id,
                name: name.isEmpty ? Self.untitledName : name,
                path: Self.abbreviated(ProjectDraft.normalizedRoot(draft.rootPath)),
                color: draft.color,
                isUnsavedNew: true
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
    var selectedTabIDs: [UUID] {
        let count = selectedPane?.tabs.count ?? 0
        let known = tabIdentities[selectedSlot] ?? []
        return (0..<count).map { index in
            index < known.count ? known[index] : Self.fallbackTabID(slot: selectedSlot, index: index)
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
        if project.rootPath.isEmpty {
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
        return result
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
        selectedSlot = 0
        stash = [:]
        tabIdentities = [:]
        isHandedInDraft = false
        nameIsAutoSuggested = false
        saveError = nil
    }

    private func load(newDraft: ProjectDraft, handedIn: Bool = false, autoSuggestedName: Bool = false) {
        draft = newDraft
        baseline = newDraft.makeProject()
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
            pendingNavigation = navigation
            return false
        }
        perform(navigation)
        return true
    }

    func requestSelect(_ id: UUID) { requestNavigation(.select(id)) }
    func requestNewProject() { requestNavigation(.newProject) }

    func resolveUnsaved(_ choice: ProjectEditorUnsavedChoice) {
        guard let navigation = pendingNavigation else { return }
        switch choice {
        case .cancel:
            pendingNavigation = nil
        case .discard:
            pendingNavigation = nil
            perform(navigation)
        case .save:
            guard save() != nil else {
                pendingNavigation = nil
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
        saveError = nil
    }

    /// The folder picked with Choose…. Pre-fills the name only when it is
    /// still empty or untitled.
    func applyChosenRoot(_ url: URL) {
        guard draft != nil else { return }
        let path = Project.standardizedRoot(url.path)
        draft?.rootPath = path
        if let current = draft?.name, nameIsAutoSuggested || Self.isUntitled(current), let suggested = suggestName(path) {
            draft?.name = suggested
        }
        saveError = nil
    }

    func setColor(_ color: SessionColor) { draft?.color = color }
    func setRunStartupCommandsOnOpen(_ value: Bool) { draft?.runStartupCommandsOnOpen = value }

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
                !($0.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
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
        stash = [:]
        tabIdentities = [:]
        selectedSlot = min(selectedSlot, max(layout.paneCount - 1, 0))
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
        updateSelectedPane { $0.tabs.remove(at: index) }
    }

    func setTabTitle(_ index: Int, _ title: String) { updateTab(index) { $0.title = title } }
    func setTabDirectory(_ index: Int, _ path: String) { updateTab(index) { $0.workingDirectory = path } }
    func setTabCommand(_ index: Int, _ command: String) { updateTab(index) { $0.startupCommand = command } }

    private func updateTab(_ index: Int, _ transform: (inout ProjectTab) -> Void) {
        updateSelectedPane { pane in
            guard pane.kind == .terminal, pane.tabs.indices.contains(index) else { return }
            transform(&pane.tabs[index])
        }
    }

    func setRepositoryPath(_ path: String) {
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
        }
        do {
            try store.upsert(project)
        } catch let error as ProjectStoreError {
            saveError = Self.message(for: error)
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
        }
    }
}
