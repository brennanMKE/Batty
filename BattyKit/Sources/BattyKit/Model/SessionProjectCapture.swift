// SessionProjectCapture.swift

import BattyXPCCore
import Foundation

/// A live Session read into Project form: the explicit, one-shot converter
/// behind Save as Project. It reads the Session and writes nothing: no
/// Session, Pane or Tab state changes, `ProjectStore` is not touched, and it
/// never runs on quit or on a timer. The result becomes a `ProjectDraft` the
/// user reviews in the Project Editor; nothing is stored until they click Save.
///
/// Captured: the split topology (direction and nesting), every Pane's kind
/// (hidden Panes included, as ordinary slots, because a Project has no
/// hidden state), each Terminal Tab's working directory relative to the root
/// and its title when the user set one, a Git Status Pane's repository
/// folder, and the Session's color.
///
/// Not captured: split ratios and every other size, startup commands (they
/// are never inferred from running processes), automatic Tab titles (a
/// process name or folder name would freeze into a wrong label), Process
/// Status pids, scrollback, and non-Terminal Panes' placeholder Tab.
struct SessionProjectCapture: Equatable {
    var layout: ProjectLayout
    /// Absolute and standardized. `NSHomeDirectory()` when the Session has no
    /// known working directory (`rootIsFallback`).
    var rootPath: String
    /// No Terminal Tab reported a working directory, so `rootPath` is only a
    /// placeholder and the editor must ask for a real root.
    var rootIsFallback: Bool
    var color: SessionColor
    /// Field messages for the editor: Tabs and repositories whose folder lies
    /// outside the root and were stored as the root instead.
    var notes: [ProjectEditorField: String]

    /// Reads the working directory a Tab is in right now, or nil when it has
    /// none that is absolute. The live value is read on purpose: this runs
    /// from a menu or button action, not from a view update.
    @MainActor
    static func workingDirectory(of tab: TabRuntime) -> String? {
        let candidates = [tab.terminal.workingDirectory, tab.workingDirectory, tab.terminal.configuration.workingDirectory]
        for candidate in candidates {
            if let candidate, candidate.hasPrefix("/") { return Project.standardizedRoot(candidate) }
        }
        return nil
    }

    /// `root` is the folder Tabs are made relative to. Nil derives it from
    /// the Session: the anchor Tab's folder (the first leaf Pane's first Tab,
    /// as auto-naming does), else the first Terminal Tab that has one, else
    /// `homeDirectory`.
    ///
    /// `gitDirectory` reads a Git Status Pane's folder; the default reads the
    /// live content, and tests supply their own so no real watcher starts.
    @MainActor
    static func capture(
        session: SessionRuntime,
        root requestedRoot: String? = nil,
        homeDirectory: String = NSHomeDirectory(),
        gitDirectory: @MainActor (PaneRuntime) -> String? = { ($0.content as? GitStatusPaneContent)?.directoryPath }
    ) -> SessionProjectCapture {
        let tree = session.tree
        let root: String
        var rootIsFallback = false
        if let requestedRoot, requestedRoot.hasPrefix("/") {
            root = Project.standardizedRoot(requestedRoot)
        } else if let derived = derivedRoot(of: tree) {
            root = derived
        } else {
            root = Project.standardizedRoot(homeDirectory)
            rootIsFallback = true
        }

        var slot = 0
        var notes: [ProjectEditorField: String] = [:]

        func capturePane(_ pane: PaneRuntime) -> ProjectPane {
            defer { slot += 1 }
            switch pane.kind {
            case .terminal:
                let tabs = pane.tabs.enumerated().map { index, tab -> ProjectTab in
                    var directory = "."
                    if let cwd = workingDirectory(of: tab) {
                        if let relative = relativePath(of: cwd, in: root) {
                            directory = relative
                        } else {
                            notes[.tabDirectory(slot: slot, tab: index)] = String(
                                localized: "This Tab was working outside the root folder, so it is set to the root. Choose a folder inside the root to change it.",
                                comment: "Project Editor: a captured Tab whose folder is outside the Project root"
                            )
                        }
                    }
                    let title = tab.titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return ProjectTab(title: title?.isEmpty == false ? title : nil, workingDirectory: directory, startupCommand: nil)
                }
                return ProjectPane(kind: .terminal, tabs: tabs)
            case .gitStatus:
                var repository: String?
                if let path = gitDirectory(pane) {
                    let standardized = Project.standardizedRoot(path)
                    if let relative = relativePath(of: standardized, in: root) {
                        repository = relative == "." ? nil : relative
                    } else {
                        notes[.repository(slot: slot)] = String(
                            localized: "This view was showing a repository outside the root folder, so it is set to the root. Choose a folder inside the root to change it.",
                            comment: "Project Editor: a captured Git Status folder outside the Project root"
                        )
                    }
                }
                return ProjectPane(kind: .gitStatus, repositoryPath: repository)
            case .processStatus, .systemMetrics, .lmStudioDashboard:
                return ProjectPane(kind: pane.kind)
            }
        }

        func captureNode(_ node: SplitTreeNode) -> ProjectLayoutNode {
            switch node {
            case .leaf(let pane):
                return .pane(capturePane(pane))
            case .split(_, let direction, _, let left, let right):
                return .split(direction: direction, children: members(of: left, direction) + members(of: right, direction))
            }
        }

        // A same-direction split nested in a split is one n-ary split: Panes
        // open at equal sizes, so `(a | (b | c))` and `(a | b | c)` are the
        // same arrangement, and the second is what the presets are.
        func members(of node: SplitTreeNode, _ direction: SplitDirection) -> [ProjectLayoutNode] {
            let child = captureNode(node)
            if case .split(let childDirection, let grandchildren) = child, childDirection == direction {
                return grandchildren
            }
            return [child]
        }

        var topology = captureNode(tree.root)
        // `PaneLayout.apply` builds the 2x2 grid column-major; the Project
        // preset is row-major. Reorder the slots so both read as the grid.
        if Self.shape(of: topology) == Self.columnMajorGridShape {
            let panes = topology.panes
            let order = [0, 2, 1, 3]
            topology = ProjectLayout.preset(.twoByTwoGrid).root.withPanes(order.map { panes[$0] })
            let swap = [1: 2, 2: 1]
            notes = Dictionary(uniqueKeysWithValues: notes.map { field, note in
                switch field {
                case .tabDirectory(let slot, let tab): (.tabDirectory(slot: swap[slot] ?? slot, tab: tab), note)
                case .repository(let slot): (.repository(slot: swap[slot] ?? slot), note)
                default: (field, note)
                }
            })
        }
        return SessionProjectCapture(
            layout: ProjectLayout(root: topology, preset: matchingPreset(for: topology)),
            rootPath: root,
            rootIsFallback: rootIsFallback,
            color: session.sessionColor,
            notes: notes
        )
    }

    @MainActor
    private static func derivedRoot(of tree: SplitTree) -> String? {
        let anchor = tree.root.firstLeafPane
        if anchor.kind == .terminal, let first = anchor.tabs.first, let cwd = workingDirectory(of: first) {
            return cwd
        }
        for pane in tree.allPanes where pane.kind == .terminal {
            for tab in pane.tabs {
                if let cwd = workingDirectory(of: tab) { return cwd }
            }
        }
        return nil
    }

    /// The preset whose split structure equals `topology`'s, comparing only
    /// direction and nesting. Nil is the editor's Custom thumbnail.
    static func matchingPreset(for topology: ProjectLayoutNode) -> PaneLayout? {
        let shape = Self.shape(of: topology)
        return PaneLayout.allCases.first { preset in
            ProjectLayout.preset(preset).root == shape
        }
    }

    private static func shape(of topology: ProjectLayoutNode) -> ProjectLayoutNode {
        topology.mappingPanes { _, _ in .terminal() }
    }

    private static let columnMajorGridShape = ProjectLayoutNode.split(direction: .horizontal, children: [
        .split(direction: .vertical, children: [.pane(.terminal()), .pane(.terminal())]),
        .split(direction: .vertical, children: [.pane(.terminal()), .pane(.terminal())]),
    ])

    /// `path` relative to `root`, "." for the root itself, or nil when it lies
    /// outside. Compared lexically first; if that fails, again with symlinks
    /// resolved on both sides (`/tmp` and `/private/tmp` name one folder).
    static func relativePath(of path: String, in root: String) -> String? {
        let candidate = Project.standardizedRoot(path)
        let base = Project.standardizedRoot(root)
        guard candidate.hasPrefix("/"), base.hasPrefix("/") else { return nil }
        if let relative = lexicalRelativePath(candidate, in: base) { return relative }
        let resolvedCandidate = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
        let resolvedBase = URL(fileURLWithPath: base).resolvingSymlinksInPath().path
        return lexicalRelativePath(resolvedCandidate, in: resolvedBase)
    }

    private static func lexicalRelativePath(_ path: String, in root: String) -> String? {
        if path == root { return "." }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    // MARK: - Draft building

    /// The Session title unless it is still the default "Session N", else the
    /// root's `ProjectNameResolver` name or folder name. `nameForRoot` is
    /// injected because the resolver reads the filesystem.
    @MainActor
    static func suggestedName(
        session: SessionRuntime,
        capture: SessionProjectCapture,
        nameForRoot: @MainActor (String) -> String? = ProjectEditorViewModel.suggestedName(forRoot:)
    ) -> String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, !AppStateStore.isDefaultSessionTitle(title) { return title }
        if !capture.rootIsFallback, let name = nameForRoot(capture.rootPath), !name.isEmpty { return name }
        return ProjectEditorViewModel.untitledName
    }

    /// `base`, or "base 2", "base 3", ... when another Project already has
    /// the name (names are unique ignoring case).
    static func uniqueName(_ base: String, among existing: [String]) -> String {
        let taken = Set(existing.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var counter = 2
        while taken.contains("\(base) \(counter)".lowercased()) { counter += 1 }
        return "\(base) \(counter)"
    }

    /// A new, unsaved Project. The run toggle starts on, as for New Project...:
    /// it only matters once the user adds a command, and the trust sheet
    /// prompts before anything runs.
    func newDraft(name: String, existingNames: [String]) -> ProjectDraft {
        var draft = ProjectDraft(
            name: Self.uniqueName(name, among: existingNames),
            rootPath: rootPath,
            color: color,
            layout: layout
        )
        draft.captureNotes = notes
        draft.rootNeedsChoosing = rootIsFallback
        return draft
    }

    /// The stored Project with its layout and Tabs replaced by this capture.
    /// Name, root, color, the run toggle and the approval carry over. A
    /// startup command stays on a Tab when the old Project had a Terminal
    /// Pane in the same slot with a Tab at the same position. This capture
    /// must have been made against `project.rootPath`.
    func updateDraft(of project: Project) -> ProjectDraft {
        var draft = ProjectDraft(project: project)
        let oldPanes = project.layout.panes
        draft.layout.root = layout.root.mappingPanes { slot, pane in
            guard pane.kind == .terminal, oldPanes.indices.contains(slot), oldPanes[slot].kind == .terminal else { return pane }
            var merged = pane
            merged.tabs = pane.tabs.enumerated().map { index, tab in
                var tab = tab
                if oldPanes[slot].tabs.indices.contains(index) {
                    tab.startupCommand = oldPanes[slot].tabs[index].startupCommand
                }
                return tab
            }
            return merged
        }
        draft.layout.preset = layout.preset
        draft.captureNotes = notes
        return draft
    }
}
