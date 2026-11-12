// SessionProjectCapture.swift

import BattyXPCCore
import Foundation

/// A live Session read into Project form: the explicit, one-shot converter
/// behind Save as Project. It reads the Session and writes nothing: no
/// Session, Pane or Tab state changes, `ProjectStore` is not touched, and it
/// never runs on quit or on a timer. The result becomes a `ProjectDraft` the
/// user reviews in the Project Editor; nothing is stored until they click Save.
///
/// Captured: the split topology (direction and nesting) and each split's
/// sizes, every Pane's kind and hidden state, the focused Pane, each Terminal
/// Pane's active Tab, each Terminal Tab's working directory relative to the
/// root, its title when the user set one and the startup command it was
/// opened with, a Git Status Pane's repository folder, and the Session's
/// color.
///
/// Not captured: startup commands are never inferred from running processes,
/// so a Tab the Project didn't open has none; automatic Tab titles (a process
/// name or folder name would freeze into a wrong label), Process Status pids,
/// scrollback, non-Terminal Panes' placeholder Tab, and the backgrounds:
/// `SaveSessionAsProject` reads the Session's, Panes' and Tabs' overrides
/// through `paneIDs` and `tabIDs`, because it has to copy files.
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
    /// The runtime Tab behind each captured Tab, by slot, for Terminal Panes.
    var tabIDs: [Int: [UUID]] = [:]
    /// The runtime Pane behind each slot.
    var paneIDs: [Int: UUID] = [:]

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
        var homeRootNote: String?
        if let requestedRoot, requestedRoot.hasPrefix("/") {
            root = Project.standardizedRoot(requestedRoot)
        } else if let derived = derivedRoot(of: tree) {
            root = derived
            if derived == Project.standardizedRoot(homeDirectory) {
                homeRootNote = String(
                    localized: "This Session is in your home folder, which is not usually a Project root.",
                    comment: "Project Editor: Save as Project from a Session at the home folder"
                )
            }
        } else {
            root = Project.standardizedRoot(homeDirectory)
            rootIsFallback = true
        }

        var slot = 0
        var notes: [ProjectEditorField: String] = [:]
        var tabIDs: [Int: [UUID]] = [:]
        var paneIDs: [Int: UUID] = [:]
        var focusedSlot = 0
        var fractions: [[Double]] = []
        if let homeRootNote { notes[.root] = homeRootNote }

        func capturePane(_ pane: PaneRuntime) -> ProjectPane {
            defer { slot += 1 }
            paneIDs[slot] = pane.id
            if pane.id == tree.focusedPaneID { focusedSlot = slot }
            var captured = captureContent(of: pane)
            captured.isHidden = pane.isHidden
            return captured
        }

        func captureContent(of pane: PaneRuntime) -> ProjectPane {
            switch pane.kind {
            case .terminal:
                tabIDs[slot] = pane.tabs.map(\.id)
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
                    return ProjectTab(title: title?.isEmpty == false ? title : nil, workingDirectory: directory, startupCommand: tab.projectStartupCommand)
                }
                let active = pane.tabs.firstIndex { $0.id == pane.activeTabID } ?? 0
                return ProjectPane(kind: .terminal, tabs: tabs, activeTab: active)
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

        // A same-direction split nested in a split is one n-ary split, so
        // `(a | (b | c))` and `(a | b | c)` are the same arrangement, and the
        // second is what the presets are. Each member's size is its share of
        // the whole chain, so the sizes survive the flattening. Fractions are
        // recorded in pre-order, the order `validFractions()` reads.
        func captureNode(_ node: SplitTreeNode) -> ProjectLayoutNode {
            guard case .split(_, let direction, _, _, _) = node else {
                if case .leaf(let pane) = node { return .pane(capturePane(pane)) }
                return .pane(.terminal())
            }
            let index = fractions.count
            fractions.append([])
            var children: [ProjectLayoutNode] = []
            var shares: [Double] = []
            func collect(_ member: SplitTreeNode, share: Double) {
                if case .split(_, let memberDirection, let ratio, let left, let right) = member, memberDirection == direction {
                    collect(left, share: share * ratio)
                    collect(right, share: share * (1 - ratio))
                } else {
                    children.append(captureNode(member))
                    shares.append(share)
                }
            }
            collect(node, share: 1)
            fractions[index] = Self.rounded(shares)
            return .split(direction: direction, children: children)
        }

        var topology = captureNode(tree.root)
        // `PaneLayout.apply` builds the 2x2 grid column-major; the Project
        // preset is row-major. Reorder the slots so both read as the grid.
        if Self.shape(of: topology) == Self.columnMajorGridShape {
            let panes = topology.panes
            let order = [0, 2, 1, 3]
            topology = ProjectLayout.preset(.twoByTwoGrid).root.withPanes(order.map { panes[$0] })
            let swap = [1: 2, 2: 1]
            tabIDs = Dictionary(uniqueKeysWithValues: tabIDs.map { (swap[$0.key] ?? $0.key, $0.value) })
            paneIDs = Dictionary(uniqueKeysWithValues: paneIDs.map { (swap[$0.key] ?? $0.key, $0.value) })
            focusedSlot = swap[focusedSlot] ?? focusedSlot
            // Column-major sizes are [columns], [left rows], [right rows]. A
            // row-major grid has one row split and the same column split in
            // each row, so the left column's rows and the column split carry.
            if fractions.count == 3 {
                fractions = [fractions[1], fractions[0], fractions[0]]
            }
            notes = Dictionary(uniqueKeysWithValues: notes.map { field, note in
                switch field {
                case .tabDirectory(let slot, let tab): (.tabDirectory(slot: swap[slot] ?? slot, tab: tab), note)
                case .repository(let slot): (.repository(slot: swap[slot] ?? slot), note)
                default: (field, note)
                }
            })
        }
        return SessionProjectCapture(
            layout: ProjectLayout(
                root: topology,
                preset: matchingPreset(for: topology),
                focusedSlot: focusedSlot,
                splitFractions: fractions.isEmpty ? nil : fractions
            ),
            rootPath: root,
            rootIsFallback: rootIsFallback,
            color: session.sessionColor,
            notes: notes,
            tabIDs: tabIDs,
            paneIDs: paneIDs
        )
    }

    /// Four decimals, with the last entry taking the rounding so each list
    /// sums to 1.
    static func rounded(_ shares: [Double]) -> [Double] {
        func round4(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }
        var result = shares.dropLast().map(round4)
        result.append(round4(1 - result.reduce(0, +)))
        return result
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

    /// The stored Project with its layout replaced whole by this capture.
    /// Name, root, symbol, color, the run toggle, the approval, sharing and
    /// the shared image carry over; `SaveSessionAsProject` fills in the rest
    /// of the Session's state. This capture must have been made against
    /// `project.rootPath`.
    func updateDraft(of project: Project) -> ProjectDraft {
        var draft = ProjectDraft(project: project)
        draft.layout = layout
        draft.captureNotes = notes
        return draft
    }
}
