// Project.swift

import BattyXPCCore
import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "Project")

extension SessionColor: Codable {}

public struct ProjectTab: Codable, Sendable, Hashable {
    public var title: String?
    /// Relative to the Project root; "." is the root itself.
    public var workingDirectory: String
    public var startupCommand: String?

    public init(title: String? = nil, workingDirectory: String = ".", startupCommand: String? = nil) {
        self.title = title
        self.workingDirectory = workingDirectory
        self.startupCommand = startupCommand
    }
}

public struct ProjectPane: Codable, Sendable, Hashable {
    public var kind: PaneContentKind
    /// Terminal Panes only. A Terminal Pane always has at least one Tab; an
    /// empty list is normalized to a single default Tab.
    public var tabs: [ProjectTab]
    /// Git Status Panes only; relative to the Project root.
    public var repositoryPath: String?

    public init(kind: PaneContentKind, tabs: [ProjectTab] = [], repositoryPath: String? = nil) {
        self.kind = kind
        self.tabs = kind == .terminal && tabs.isEmpty ? [ProjectTab()] : tabs
        self.repositoryPath = repositoryPath
    }

    public static func terminal(tabs: [ProjectTab] = [ProjectTab()]) -> ProjectPane {
        ProjectPane(kind: .terminal, tabs: tabs)
    }

    private enum CodingKeys: String, CodingKey {
        case kind, tabs, repositoryPath
    }

    /// A missing or unknown `kind` throws; it must never fall back to
    /// `.terminal` the way `Pane`'s lenient decoder does.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(PaneContentKind.self, forKey: .kind)
        let decodedTabs = try c.decodeIfPresent([ProjectTab].self, forKey: .tabs) ?? []
        tabs = kind == .terminal && decodedTabs.isEmpty ? [ProjectTab()] : decodedTabs
        repositoryPath = try c.decodeIfPresent(String.self, forKey: .repositoryPath)
    }
}

/// A split topology with no ratio, size or geometry. Slot order is the
/// depth-first, in-order traversal of `.pane` leaves.
public indirect enum ProjectLayoutNode: Codable, Sendable, Hashable {
    case pane(ProjectPane)
    case split(direction: SplitDirection, children: [ProjectLayoutNode])

    private enum CodingKeys: String, CodingKey {
        case type, pane, direction, children
    }

    private enum NodeType: String, Codable {
        case pane, split
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(NodeType.self, forKey: .type) {
        case .pane:
            self = .pane(try c.decode(ProjectPane.self, forKey: .pane))
        case .split:
            let children = try c.decode([ProjectLayoutNode].self, forKey: .children)
            guard children.count >= 2 else {
                throw DecodingError.dataCorruptedError(forKey: .children, in: c, debugDescription: "a split needs at least two children")
            }
            self = .split(direction: try c.decode(SplitDirection.self, forKey: .direction), children: children)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let pane):
            try c.encode(NodeType.pane, forKey: .type)
            try c.encode(pane, forKey: .pane)
        case .split(let direction, let children):
            try c.encode(NodeType.split, forKey: .type)
            try c.encode(direction, forKey: .direction)
            try c.encode(children, forKey: .children)
        }
    }

    public var panes: [ProjectPane] {
        switch self {
        case .pane(let pane): [pane]
        case .split(_, let children): children.flatMap(\.panes)
        }
    }
}

public struct ProjectLayout: Codable, Sendable, Hashable {
    public var root: ProjectLayoutNode
    /// The preset this topology was derived from, so the editor can highlight
    /// its thumbnail. Nil for a captured or hand-edited arrangement.
    public var preset: PaneLayout?

    public init(root: ProjectLayoutNode, preset: PaneLayout? = nil) {
        self.root = root
        self.preset = preset
    }

    private enum CodingKeys: String, CodingKey {
        case root, preset
    }

    /// An unrecognized `preset` only costs the editor its thumbnail
    /// highlight, so it decodes to nil rather than failing the Project.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        root = try c.decode(ProjectLayoutNode.self, forKey: .root)
        preset = (try? c.decodeIfPresent(String.self, forKey: .preset)).flatMap(PaneLayout.init(rawValue:))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(root, forKey: .root)
        try c.encodeIfPresent(preset?.rawValue, forKey: .preset)
    }

    /// Panes in slot order.
    public var panes: [ProjectPane] { root.panes }
    public var paneCount: Int { panes.count }
    public var tabCount: Int { panes.reduce(0) { $0 + $1.tabs.count } }

    /// The topology for each preset is canonical for Projects. `.twoByTwoGrid`
    /// is row-major, a vertical split of two horizontal splits, which differs
    /// from the nesting `PaneLayout.apply(to:)` builds; the slot order is the
    /// same.
    ///
    /// Slot order matches `PaneLayout.layoutPanes`. `kinds[i]` is the kind of
    /// slot `i`; missing or extra entries default to `.terminal` / are ignored.
    public static func preset(_ preset: PaneLayout, kinds: [PaneContentKind] = []) -> ProjectLayout {
        var slot = 0
        func leaf() -> ProjectLayoutNode {
            defer { slot += 1 }
            let kind = slot < kinds.count ? kinds[slot] : .terminal
            return .pane(kind == .terminal ? .terminal() : ProjectPane(kind: kind))
        }
        let root: ProjectLayoutNode
        switch preset {
        case .singlePane:
            root = leaf()
        case .horizontalSplit:
            root = .split(direction: .horizontal, children: [leaf(), leaf()])
        case .verticalSplit:
            root = .split(direction: .vertical, children: [leaf(), leaf()])
        case .threeColumns:
            root = .split(direction: .horizontal, children: [leaf(), leaf(), leaf()])
        case .threeRows:
            root = .split(direction: .vertical, children: [leaf(), leaf(), leaf()])
        case .mainLeftTwoRight:
            let main = leaf()
            root = .split(direction: .horizontal, children: [main, .split(direction: .vertical, children: [leaf(), leaf()])])
        case .mainRightTwoLeft:
            let left = ProjectLayoutNode.split(direction: .vertical, children: [leaf(), leaf()])
            root = .split(direction: .horizontal, children: [left, leaf()])
        case .mainTopTwoBottom:
            let main = leaf()
            root = .split(direction: .vertical, children: [main, .split(direction: .horizontal, children: [leaf(), leaf()])])
        case .mainBottomTwoTop:
            let top = ProjectLayoutNode.split(direction: .horizontal, children: [leaf(), leaf()])
            root = .split(direction: .vertical, children: [top, leaf()])
        case .twoByTwoGrid:
            let top = ProjectLayoutNode.split(direction: .horizontal, children: [leaf(), leaf()])
            let bottom = ProjectLayoutNode.split(direction: .horizontal, children: [leaf(), leaf()])
            root = .split(direction: .vertical, children: [top, bottom])
        }
        return ProjectLayout(root: root, preset: preset)
    }
}

public struct ProjectStartupCommand: Sendable, Hashable {
    public var paneIndex: Int
    public var tabIndex: Int
    public var command: String
}

public struct Project: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// Absolute and lexically standardized. A non-absolute value is rejected
    /// at decode and resolves no paths.
    public var rootPath: String
    public var color: SessionColor
    /// Absent in files written before symbols existed; decodes to `.folder`.
    public var symbol: ProjectSymbol
    public var layout: ProjectLayout
    public var runStartupCommandsOnOpen: Bool
    public var approvedCommandsHash: String?
    public var lastOpenedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        rootPath: String,
        color: SessionColor = .blue,
        symbol: ProjectSymbol = .folder,
        layout: ProjectLayout = .preset(.singlePane),
        runStartupCommandsOnOpen: Bool = false,
        approvedCommandsHash: String? = nil,
        lastOpenedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.rootPath = Project.standardizedRoot(rootPath)
        self.color = color
        self.symbol = symbol
        self.layout = layout
        self.runStartupCommandsOnOpen = runStartupCommandsOnOpen
        self.approvedCommandsHash = approvedCommandsHash
        self.lastOpenedAt = lastOpenedAt
    }

    public var paneCount: Int { layout.paneCount }
    public var tabCount: Int { layout.tabCount }

    /// Non-blank commands in pane/tab order.
    public var startupCommands: [ProjectStartupCommand] {
        var result: [ProjectStartupCommand] = []
        for (paneIndex, pane) in layout.panes.enumerated() {
            for (tabIndex, tab) in pane.tabs.enumerated() {
                guard let command = tab.startupCommand,
                      !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                result.append(ProjectStartupCommand(paneIndex: paneIndex, tabIndex: tabIndex, command: command))
            }
        }
        return result
    }

    public var startupCommandCount: Int { startupCommands.count }

    /// Purely lexical: resolves "." and ".." without consulting the
    /// filesystem, so the result does not depend on which paths exist. A
    /// non-absolute path is returned unchanged.
    public static func standardizedRoot(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Resolves `path` (relative to the root, or absolute inside it) to a
    /// standardized URL. Returns nil when it escapes the root after
    /// standardization. Symlinks are not resolved.
    public func resolve(_ path: String) -> URL? {
        guard rootPath.hasPrefix("/") else { return nil }
        let root = Project.standardizedRoot(rootPath)
        let candidate = path.hasPrefix("/")
            ? Project.standardizedRoot(path)
            : Project.standardizedRoot((root as NSString).appendingPathComponent(path))
        let rootWithSlash = root.hasSuffix("/") ? root : root + "/"
        guard candidate == root || candidate.hasPrefix(rootWithSlash) else { return nil }
        return URL(fileURLWithPath: candidate)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, rootPath, color, symbol, layout, runStartupCommandsOnOpen, approvedCommandsHash, lastOpenedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        let decodedRoot = try c.decode(String.self, forKey: .rootPath)
        guard decodedRoot.hasPrefix("/") else {
            throw DecodingError.dataCorruptedError(forKey: .rootPath, in: c, debugDescription: "rootPath must be absolute")
        }
        rootPath = Project.standardizedRoot(decodedRoot)
        if let raw = try? c.decodeIfPresent(Int.self, forKey: .color), let decoded = SessionColor(rawValue: raw) {
            color = decoded
        } else {
            if c.contains(.color) { logger.error("unrecognized project color; using the default") }
            color = .blue
        }
        if let raw = try? c.decodeIfPresent(String.self, forKey: .symbol), let decoded = ProjectSymbol(rawValue: raw) {
            symbol = decoded
        } else {
            if c.contains(.symbol) { logger.error("unrecognized project symbol; using the default") }
            symbol = .folder
        }
        layout = try c.decode(ProjectLayout.self, forKey: .layout)
        runStartupCommandsOnOpen = try c.decodeIfPresent(Bool.self, forKey: .runStartupCommandsOnOpen) ?? false
        approvedCommandsHash = try c.decodeIfPresent(String.self, forKey: .approvedCommandsHash)
        if let decoded = try? c.decodeIfPresent(Date.self, forKey: .lastOpenedAt) {
            lastOpenedAt = decoded
        } else {
            if c.contains(.lastOpenedAt), !((try? c.decodeNil(forKey: .lastOpenedAt)) ?? false) { logger.error("unreadable project lastOpenedAt; treating the project as never opened") }
            lastOpenedAt = nil
        }
    }
}
