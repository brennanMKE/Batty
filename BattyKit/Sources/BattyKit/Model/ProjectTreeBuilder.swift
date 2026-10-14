// ProjectTreeBuilder.swift

import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "ProjectTreeBuilder")

public enum ProjectOpenError: Error, Equatable, LocalizedError {
    case unknownProject(UUID)
    case noWindow
    case invalidRoot(String)
    case rootMissing(String)
    case rootNotADirectory(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unknownProject:
            String(localized: "That Project no longer exists.")
        case .noWindow:
            String(localized: "There is no window to open the Project in.")
        case .invalidRoot(let path):
            String(localized: "The Project folder \u{201C}\(path)\u{201D} is not an absolute path.")
        case .rootMissing(let path):
            String(localized: "The Project folder \u{201C}\(path)\u{201D} no longer exists.")
        case .rootNotADirectory(let path):
            String(localized: "The Project folder \u{201C}\(path)\u{201D} is not a folder.")
        case .cancelled:
            String(localized: "Opening the Project was cancelled.")
        }
    }
}

/// Replays a `ProjectLayout` topology as a `SplitTree` through the same
/// `SplitTree.splitPane` machinery a user's own splits go through, so ratios
/// come out of the #0255 chain equalization exactly as they would by hand.
@MainActor
enum ProjectTreeBuilder {
    typealias ContentFactory = @MainActor (PaneContentKind) -> (any PaneContentLifecycle)?

    /// Throws before constructing anything when the Project root is unusable.
    /// A Tab or repository directory that is missing, or that escapes the
    /// root, falls back to the root instead of failing the open.
    static func build(
        project: Project,
        contentFactory: ContentFactory? = nil,
        gitStatusContent: ((String) -> (any PaneContentLifecycle)?)? = nil,
        isSessionSelected: Bool,
        fileManager: FileManager = .default
    ) throws -> SplitTree {
        guard let rootURL = project.resolve(".") else {
            throw ProjectOpenError.invalidRoot(project.rootPath)
        }
        let root = rootURL.path
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root, isDirectory: &isDirectory) else {
            throw ProjectOpenError.rootMissing(root)
        }
        guard isDirectory.boolValue else {
            throw ProjectOpenError.rootNotADirectory(root)
        }

        func directory(_ relative: String) -> String {
            guard let url = project.resolve(relative) else {
                logger.notice("project-open: path escapes root; using root relative=\(relative, privacy: .private)")
                return root
            }
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                logger.notice("project-open: directory missing; using root relative=\(relative, privacy: .private)")
                return root
            }
            return url.path
        }

        struct Slot {
            var kind: PaneContentKind
            var tabs: [TabRuntime]?
            var path: String?
        }

        func slot(for pane: ProjectPane) -> Slot {
            switch pane.kind {
            case .terminal:
                let tabs = pane.tabs.map { tab in
                    let title = tab.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return TabRuntime(
                        titleOverride: (title?.isEmpty ?? true) ? nil : title,
                        workingDirectory: directory(tab.workingDirectory)
                    )
                }
                return Slot(kind: .terminal, tabs: tabs.isEmpty ? nil : tabs, path: nil)
            case .gitStatus:
                return Slot(kind: .gitStatus, tabs: nil, path: directory(pane.repositoryPath ?? "."))
            case .processStatus, .systemMetrics, .lmStudioDashboard:
                return Slot(kind: pane.kind, tabs: nil, path: nil)
            }
        }

        // `gitStatusContent` exists so a unit test can observe the resolved
        // repository path without constructing a real FSEventStream-backed
        // conformer; an explicit `contentFactory` still wins outright.
        func factory(for slot: Slot) -> ContentFactory? {
            if let contentFactory { return contentFactory }
            guard slot.kind == .gitStatus, let gitStatusContent, let path = slot.path else { return nil }
            return { _ in gitStatusContent(path) }
        }

        let layoutRoot = project.layout.root
        let first = slot(for: layoutRoot.firstPane)
        let tree = SplitTree.withFirstPane(
            kind: first.kind,
            path: first.path,
            tabs: first.tabs,
            contentFactory: factory(for: first),
            isSessionSelected: isSessionSelected
        )
        let firstPane = tree.focusedPane

        // `anchor` is the existing Pane that becomes `node`'s first leaf.
        // All of a split's siblings are created before any child is
        // expanded, so each split sequence matches the by-hand one
        // `PaneLayout.apply(to:)` performs for the same arrangement.
        func expand(_ node: ProjectLayoutNode, anchor: PaneRuntime) {
            guard case .split(let direction, let children) = node else { return }
            var anchors = [anchor]
            var previous = anchor
            for child in children.dropFirst() {
                let spec = slot(for: child.firstPane)
                guard let created = tree.splitPane(
                    id: previous.id,
                    direction: direction,
                    kind: spec.kind,
                    path: spec.path,
                    tabs: spec.tabs,
                    contentFactory: factory(for: spec),
                    isSessionSelected: isSessionSelected
                ) else {
                    logger.error("project-open: split failed; abandoning remaining slots")
                    return
                }
                anchors.append(created)
                previous = created
            }
            for (child, childAnchor) in zip(children, anchors) {
                expand(child, anchor: childAnchor)
            }
        }
        expand(layoutRoot, anchor: firstPane)

        tree.focusedPaneID = firstPane.id
        return tree
    }
}

private extension ProjectLayoutNode {
    var firstPane: ProjectPane {
        switch self {
        case .pane(let pane): pane
        case .split(_, let children): children[0].firstPane
        }
    }
}
