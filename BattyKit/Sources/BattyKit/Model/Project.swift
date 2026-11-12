// Project.swift

import BattyXPCCore
import Foundation
import os
import SwiftUI

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "Project")

extension SessionColor: Codable {}

public struct ProjectTab: Codable, Sendable, Hashable {
    public var title: String?
    /// Relative to the Project root; "." is the root itself.
    public var workingDirectory: String
    public var startupCommand: String?
    /// `nil` follows the Pane's, then the Project's background. A value is
    /// restored as this Tab's own background when the Project opens. The image path is device
    /// state and the rest is definition.
    public var background: TerminalBackgroundSettings?
    /// Which image `background` shows, in a form another Mac can find. Set only
    /// with a background; the path in `background` is this Mac's copy of it.
    public var image: ProjectTabImage?

    public init(title: String? = nil, workingDirectory: String = ".", startupCommand: String? = nil, background: TerminalBackgroundSettings? = nil, image: ProjectTabImage? = nil) {
        self.title = title
        self.workingDirectory = workingDirectory
        self.startupCommand = startupCommand
        self.background = background
        self.image = background == nil ? nil : image
    }

    private enum CodingKeys: String, CodingKey {
        case title, workingDirectory, startupCommand, background, image
    }

    /// Optional keys are written only when set, so a Tab with no background
    /// encodes as it did before Tabs had one.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(workingDirectory, forKey: .workingDirectory)
        try c.encodeIfPresent(startupCommand, forKey: .startupCommand)
        try c.encodeIfPresent(background, forKey: .background)
        try c.encodeIfPresent(background == nil ? nil : image, forKey: .image)
    }

    /// A bad `background` costs only this Tab its background.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        workingDirectory = try c.decode(String.self, forKey: .workingDirectory)
        startupCommand = try c.decodeIfPresent(String.self, forKey: .startupCommand)
        if let decoded = try? c.decodeIfPresent(TerminalBackgroundSettings.self, forKey: .background) {
            background = decoded
        } else {
            if c.contains(.background), !((try? c.decodeNil(forKey: .background)) ?? false) { logger.error("unreadable project tab background; following the Project") }
            background = nil
        }
        image = background == nil ? nil : ProjectTabImage.decodeTolerantly(from: c, forKey: .image)
    }
}

public struct ProjectPane: Codable, Sendable, Hashable {
    public var kind: PaneContentKind
    /// Terminal Panes only. A Terminal Pane always has at least one Tab; an
    /// empty list is normalized to a single default Tab.
    public var tabs: [ProjectTab]
    /// Git Status Panes only; relative to the Project root.
    public var repositoryPath: String?
    /// Terminal Panes only. `nil` follows the Project's background; a value is
    /// restored as this Pane's background when the Project opens. The image
    /// path is device state and the rest is definition, as for a Tab.
    public var background: TerminalBackgroundSettings?
    /// Which image `background` shows, in a form another Mac can find. Set
    /// only with a background.
    public var image: ProjectTabImage?
    /// Restored hidden at open, unless it would hide the last visible Pane.
    public var isHidden: Bool
    /// Terminal Panes only: the index of the active Tab. `nil` is the first;
    /// an index out of range is ignored at open.
    public var activeTab: Int?

    public init(
        kind: PaneContentKind,
        tabs: [ProjectTab] = [],
        repositoryPath: String? = nil,
        background: TerminalBackgroundSettings? = nil,
        image: ProjectTabImage? = nil,
        isHidden: Bool = false,
        activeTab: Int? = nil
    ) {
        self.kind = kind
        self.tabs = kind == .terminal && tabs.isEmpty ? [ProjectTab()] : tabs
        self.repositoryPath = repositoryPath
        self.background = background
        self.image = background == nil ? nil : image
        self.isHidden = isHidden
        self.activeTab = activeTab.flatMap { $0 > 0 ? $0 : nil }
    }

    public static func terminal(tabs: [ProjectTab] = [ProjectTab()]) -> ProjectPane {
        ProjectPane(kind: .terminal, tabs: tabs)
    }

    private enum CodingKeys: String, CodingKey {
        case kind, tabs, repositoryPath, background, image, isHidden, activeTab
    }

    /// Optional keys are written only when set, so a Pane without them encodes
    /// as it did before Panes had them.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(tabs, forKey: .tabs)
        try c.encodeIfPresent(repositoryPath, forKey: .repositoryPath)
        try c.encodeIfPresent(background, forKey: .background)
        try c.encodeIfPresent(background == nil ? nil : image, forKey: .image)
        if isHidden { try c.encode(true, forKey: .isHidden) }
        if let activeTab, activeTab > 0 { try c.encode(activeTab, forKey: .activeTab) }
    }

    /// A missing or unknown `kind` throws; it must never fall back to
    /// `.terminal` the way `Pane`'s lenient decoder does. A bad value in any
    /// of the later fields costs only that field.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(PaneContentKind.self, forKey: .kind)
        let decodedTabs = try c.decodeIfPresent([ProjectTab].self, forKey: .tabs) ?? []
        tabs = kind == .terminal && decodedTabs.isEmpty ? [ProjectTab()] : decodedTabs
        repositoryPath = try c.decodeIfPresent(String.self, forKey: .repositoryPath)
        if let decoded = try? c.decodeIfPresent(TerminalBackgroundSettings.self, forKey: .background) {
            background = decoded
        } else {
            if c.contains(.background), !((try? c.decodeNil(forKey: .background)) ?? false) { logger.error("unreadable project pane background; following the Project") }
            background = nil
        }
        image = background == nil ? nil : ProjectTabImage.decodeTolerantly(from: c, forKey: .image)
        isHidden = (try? c.decodeIfPresent(Bool.self, forKey: .isHidden)) ?? false
        activeTab = ((try? c.decodeIfPresent(Int.self, forKey: .activeTab)) ?? nil).flatMap { $0 > 0 ? $0 : nil }
    }
}

/// One background level stored in a layout: a Terminal Pane's own, or one of
/// its Tabs'.
struct ProjectBackgroundEntry: Hashable {
    var background: TerminalBackgroundSettings?
    var image: ProjectTabImage?
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

extension ProjectLayout {
    /// Every Terminal Pane's own background entry, then its Tabs', in slot
    /// order.
    var backgroundEntries: [ProjectBackgroundEntry] {
        panes.flatMap { pane -> [ProjectBackgroundEntry] in
            let own = pane.kind == .terminal ? [ProjectBackgroundEntry(background: pane.background, image: pane.image)] : []
            return own + pane.tabs.map { ProjectBackgroundEntry(background: $0.background, image: $0.image) }
        }
    }

    /// Each Pane's and Tab's background entry replaced by `transform` of it.
    func mappingBackgroundEntries(_ transform: (ProjectBackgroundEntry) -> ProjectBackgroundEntry) -> ProjectLayout {
        var copy = self
        copy.root = root.mappingPanes { _, pane in
            var mapped = pane
            if pane.kind == .terminal {
                let entry = transform(ProjectBackgroundEntry(background: pane.background, image: pane.image))
                mapped.background = entry.background
                mapped.image = entry.background == nil ? nil : entry.image
            }
            mapped.tabs = pane.tabs.map { tab in
                var tab = tab
                let entry = transform(ProjectBackgroundEntry(background: tab.background, image: tab.image))
                tab.background = entry.background
                tab.image = entry.background == nil ? nil : entry.image
                return tab
            }
            return mapped
        }
        return copy
    }

    /// Content-addressed: an incoming Pane or Tab takes this Mac's path for
    /// the same identity, wherever it now sits, or no path, which means its
    /// image hasn't reached this Mac. One with no identity has no image.
    func carryingTabImagePaths(from local: ProjectLayout) -> ProjectLayout {
        var paths: [ProjectTabImage: String] = [:]
        for entry in local.backgroundEntries {
            guard let image = entry.image, let path = entry.background?.imagePath, paths[image] == nil else { continue }
            paths[image] = path
        }
        return mappingBackgroundEntries { entry in
            var entry = entry
            entry.background = entry.background?.withImagePath(entry.image.flatMap { paths[$0] })
            return entry
        }
    }

    func mappingTabs(_ transform: (ProjectTab) -> ProjectTab) -> ProjectLayout {
        var copy = self
        copy.root = root.mappingPanes { _, pane in
            var mapped = pane
            mapped.tabs = pane.tabs.map(transform)
            return mapped
        }
        return copy
    }

    /// Each Terminal Pane's and Tab's background replaced by `transform` of
    /// it; levels with none are left alone.
    func mappingTabBackgrounds(_ transform: (TerminalBackgroundSettings) -> TerminalBackgroundSettings?) -> ProjectLayout {
        mappingBackgroundEntries { entry in
            var entry = entry
            entry.background = entry.background.flatMap(transform)
            if entry.background == nil { entry.image = nil }
            return entry
        }
    }

    /// The number of `.split` nodes and each one's child count, in pre-order.
    var splitShape: [Int] {
        func walk(_ node: ProjectLayoutNode) -> [Int] {
            switch node {
            case .pane: []
            case .split(_, let children): [children.count] + children.flatMap(walk)
            }
        }
        return walk(root)
    }

    /// `splitFractions` when they fit the topology: one array per split in
    /// pre-order, each with one fraction in (0, 1) per child. Anything else is
    /// nil, so the Project opens at equal sizes.
    func validFractions() -> [[Double]]? {
        guard let splitFractions else { return nil }
        let shape = splitShape
        guard splitFractions.count == shape.count,
              zip(splitFractions, shape).allSatisfy({ fractions, count in
                  fractions.count == count && fractions.allSatisfy { $0 > 0 && $0 < 1 }
              })
        else { return nil }
        return splitFractions
    }
}

public struct ProjectLayout: Codable, Sendable, Hashable {
    public var root: ProjectLayoutNode
    /// The preset this topology was derived from, so the editor can highlight
    /// its thumbnail. Nil for a captured or hand-edited arrangement.
    public var preset: PaneLayout?
    /// The slot of the focused Pane. `nil` is the first.
    public var focusedSlot: Int?
    /// Each split's child sizes, one array per `.split` node in pre-order,
    /// each summing to 1. `nil`, or a list that doesn't fit the topology,
    /// opens at equal sizes. See ``validFractions()``.
    public var splitFractions: [[Double]]?

    public init(root: ProjectLayoutNode, preset: PaneLayout? = nil, focusedSlot: Int? = nil, splitFractions: [[Double]]? = nil) {
        self.root = root
        self.preset = preset
        self.focusedSlot = focusedSlot.flatMap { $0 > 0 ? $0 : nil }
        self.splitFractions = splitFractions
    }

    private enum CodingKeys: String, CodingKey {
        case root, preset, focusedSlot, splitFractions
    }

    /// An unrecognized `preset` only costs the editor its thumbnail
    /// highlight, so it decodes to nil rather than failing the Project. A bad
    /// focus or size list costs only itself.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        root = try c.decode(ProjectLayoutNode.self, forKey: .root)
        preset = (try? c.decodeIfPresent(String.self, forKey: .preset)).flatMap(PaneLayout.init(rawValue:))
        focusedSlot = ((try? c.decodeIfPresent(Int.self, forKey: .focusedSlot)) ?? nil).flatMap { $0 > 0 ? $0 : nil }
        splitFractions = (try? c.decodeIfPresent([[Double]].self, forKey: .splitFractions)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(root, forKey: .root)
        try c.encodeIfPresent(preset?.rawValue, forKey: .preset)
        if let focusedSlot, focusedSlot > 0 { try c.encode(focusedSlot, forKey: .focusedSlot) }
        try c.encodeIfPresent(splitFractions, forKey: .splitFractions)
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

/// What a Shared Project has published about its image. A bad digest fails the
/// decode, which `Project` turns into nil, so it never builds a path.
public enum ProjectSharedImage: Codable, Sendable, Hashable {
    case named(digest: String, name: String)
    case removed

    public var digest: String? {
        if case .named(let digest, _) = self { return digest }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case digest, name, removed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if (try? c.decodeIfPresent(Bool.self, forKey: .removed)) == true {
            self = .removed
            return
        }
        let digest = try c.decode(String.self, forKey: .digest)
        guard TerminalBackgroundImageImporter.isDigest(digest) else {
            throw DecodingError.dataCorruptedError(forKey: .digest, in: c, debugDescription: "not a digest")
        }
        let name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        self = .named(digest: digest, name: TerminalBackgroundImageImporter.sanitizedImageName(name, maxBytes: Self.maxNameBytes))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .named(let digest, let name):
            try c.encode(digest, forKey: .digest)
            try c.encode(name, forKey: .name)
        case .removed:
            try c.encode(true, forKey: .removed)
        }
    }

    nonisolated static let maxNameBytes = 100

    /// Nil when `path` isn't in a folder named for a digest.
    static func named(fromPath path: String) -> ProjectSharedImage? {
        guard let digest = TerminalBackgroundImageImporter.digest(ofPath: path) else { return nil }
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return .named(digest: digest, name: TerminalBackgroundImageImporter.sanitizedImageName(name, maxBytes: maxNameBytes))
    }

    /// What a Save of a Shared Project publishes. `stored` is the Project as it
    /// was before this Save.
    static func forSave(draft: Project, stored: Project?) -> ProjectSharedImage? {
        guard let background = draft.background else { return nil }
        if let path = background.imagePath {
            if path == stored?.background?.imagePath, case .named = draft.sharedImage {
                return draft.sharedImage
            }
            return named(fromPath: path)
        }
        if stored?.background?.imagePath != nil { return .removed }
        if draft.sharedImage == nil, stored?.sharedImage?.digest != nil { return .removed }
        return draft.sharedImage
    }
}

public struct Project: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// Absolute and lexically standardized. A non-absolute value is rejected
    /// at decode and resolves no paths.
    public var rootPath: String
    /// The legacy palette color: the exact entry that was picked, or the
    /// entry nearest `customColorHex`. Always written, so older Batty
    /// versions read a valid color.
    public var color: SessionColor
    /// `#RRGGBB` for a color picked outside the palette. Wins over `color`
    /// when drawing. Older Batty versions ignore and, on their next save,
    /// drop it.
    public var customColorHex: String?
    /// Absent in files written before symbols existed; decodes to `.folder`.
    /// For an arbitrary SF Symbol this is `.folder`, the legacy fallback.
    public var symbol: ProjectSymbol
    /// The SF Symbol name for a symbol outside the 37 curated cases. Wins over
    /// `symbol` when drawing. Older Batty versions ignore and, on their next
    /// save, drop it.
    public var customSymbolName: String?
    public var layout: ProjectLayout
    public var runStartupCommandsOnOpen: Bool
    public var approvedCommandsHash: String?
    public var lastOpenedAt: Date?
    /// Marked to sync through iCloud. Absent in the file decodes to `false`,
    /// so every Project written before sharing existed is local.
    public var isShared: Bool
    /// When the definition last changed, the last-writer-wins key for a
    /// shared Project. Not set by opening or by storing a startup-command approval, which touch device state only.
    public var modifiedAt: Date?
    /// `nil` follows Settings. A value is restored as the Session's background
    /// when the Project opens, and one with no image hides any app-wide image. The image
    /// path is device state and the rest is definition. Older Batty versions
    /// ignore and, on their next save, drop it.
    public var background: TerminalBackgroundSettings?
    /// Nil means this Project has never published an image. `.named` with a
    /// digest other than `imagePath`'s means the image hasn't arrived yet.
    public var sharedImage: ProjectSharedImage?
    /// `nil` follows Settings. A value is restored as the Session's Theme when
    /// the Project opens; an unset or unknown slot follows Settings for that
    /// appearance. Definition; older Batty ignores and drops it on save.
    public var theme: ThemePair?
    /// The Session's bell mute, restored at open.
    public var notificationsMuted: Bool
    /// Whether the Sidebar lists the Session's Panes, restored at open.
    public var paneListExpanded: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        rootPath: String,
        color: SessionColor = .blue,
        symbol: ProjectSymbol = .folder,
        layout: ProjectLayout = .preset(.singlePane),
        runStartupCommandsOnOpen: Bool = false,
        approvedCommandsHash: String? = nil,
        lastOpenedAt: Date? = nil,
        isShared: Bool = false,
        modifiedAt: Date? = nil,
        customColorHex: String? = nil,
        customSymbolName: String? = nil,
        background: TerminalBackgroundSettings? = nil,
        sharedImage: ProjectSharedImage? = nil,
        theme: ThemePair? = nil,
        notificationsMuted: Bool = false,
        paneListExpanded: Bool = false
    ) {
        let resolvedColor = ProjectAppearance.resolve(color: color, customHex: customColorHex)
        let resolvedSymbol = ProjectAppearance.resolve(symbol: symbol, customName: customSymbolName)
        self.id = id
        self.name = name
        self.rootPath = Project.standardizedRoot(rootPath)
        self.color = resolvedColor.color
        self.customColorHex = resolvedColor.customHex
        self.symbol = resolvedSymbol.symbol
        self.customSymbolName = resolvedSymbol.customName
        self.layout = layout
        self.runStartupCommandsOnOpen = runStartupCommandsOnOpen
        self.approvedCommandsHash = approvedCommandsHash
        self.lastOpenedAt = lastOpenedAt
        self.isShared = isShared
        self.modifiedAt = modifiedAt
        self.background = background
        self.sharedImage = sharedImage
        self.theme = theme?.normalized
        self.notificationsMuted = notificationsMuted
        self.paneListExpanded = paneListExpanded
    }

    /// The image this Mac is still waiting for, if any.
    var pendingSharedImage: (digest: String, name: String)? {
        guard case .named(let digest, let name) = sharedImage,
              background?.imagePath.flatMap(TerminalBackgroundImageImporter.digest(ofPath:)) != digest
        else { return nil }
        return (digest, name)
    }

    /// The color to draw: the custom color, else the palette entry.
    public var displayColor: Color { ProjectAppearance.color(palette: color, customHex: customColorHex) }
    /// The SF Symbol to draw; never a name this OS cannot draw.
    public var displaySystemName: String { ProjectAppearance.systemName(symbol: symbol, customName: customSymbolName) }

    public var paneCount: Int { layout.paneCount }
    public var tabCount: Int { layout.tabCount }

    /// Every Pane's and Tab's image path, in slot order, deduped.
    public var tabBackgroundImagePaths: [String] {
        var seen = Set<String>()
        return layout.backgroundEntries.compactMap(\.background?.imagePath).filter { seen.insert($0).inserted }
    }

    /// Every Pane's and Tab's image identity.
    public var tabImages: Set<ProjectTabImage> {
        Set(layout.backgroundEntries.compactMap(\.image))
    }

    public var tabCustomDigests: Set<String> {
        Set(tabImages.compactMap(\.digest))
    }

    /// The Project's image path and every Pane's and Tab's, deduped.
    public var allBackgroundImagePaths: [String] {
        var seen = Set<String>()
        return ([background?.imagePath].compactMap { $0 } + tabBackgroundImagePaths).filter { seen.insert($0).inserted }
    }

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
        case id, name, rootPath, color, customColor, symbol, symbolName, layout, runStartupCommandsOnOpen, approvedCommandsHash, lastOpenedAt, isShared, modifiedAt, background, sharedImage, theme, notificationsMuted, paneListExpanded
    }

    /// `isShared` is written only when true, so a local Project's object is
    /// byte-identical to one written before sharing existed.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(rootPath, forKey: .rootPath)
        try c.encode(color, forKey: .color)
        try c.encodeIfPresent(customColorHex, forKey: .customColor)
        try c.encode(symbol, forKey: .symbol)
        try c.encodeIfPresent(customSymbolName, forKey: .symbolName)
        try c.encode(layout, forKey: .layout)
        try c.encode(runStartupCommandsOnOpen, forKey: .runStartupCommandsOnOpen)
        try c.encodeIfPresent(approvedCommandsHash, forKey: .approvedCommandsHash)
        try c.encodeIfPresent(lastOpenedAt, forKey: .lastOpenedAt)
        if isShared { try c.encode(true, forKey: .isShared) }
        try c.encodeIfPresent(modifiedAt, forKey: .modifiedAt)
        try c.encodeIfPresent(background, forKey: .background)
        try c.encodeIfPresent(sharedImage, forKey: .sharedImage)
        try c.encodeIfPresent(theme, forKey: .theme)
        if notificationsMuted { try c.encode(true, forKey: .notificationsMuted) }
        if paneListExpanded { try c.encode(true, forKey: .paneListExpanded) }
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
        let decodedCustomColor = (try? c.decodeIfPresent(String.self, forKey: .customColor)) ?? nil
        if c.contains(.customColor), ProjectAppearance.normalizedHex(decodedCustomColor) == nil {
            logger.error("unreadable project custom color; using the palette color")
        }
        let resolvedColor = ProjectAppearance.resolve(color: color, customHex: decodedCustomColor)
        color = resolvedColor.color
        customColorHex = resolvedColor.customHex
        let decodedSymbolName = (try? c.decodeIfPresent(String.self, forKey: .symbolName)) ?? nil
        let resolvedSymbol = ProjectAppearance.resolve(symbol: symbol, customName: decodedSymbolName)
        symbol = resolvedSymbol.symbol
        customSymbolName = resolvedSymbol.customName
        layout = try c.decode(ProjectLayout.self, forKey: .layout)
        runStartupCommandsOnOpen = try c.decodeIfPresent(Bool.self, forKey: .runStartupCommandsOnOpen) ?? false
        approvedCommandsHash = try c.decodeIfPresent(String.self, forKey: .approvedCommandsHash)
        if let decoded = try? c.decodeIfPresent(Date.self, forKey: .lastOpenedAt) {
            lastOpenedAt = decoded
        } else {
            if c.contains(.lastOpenedAt), !((try? c.decodeNil(forKey: .lastOpenedAt)) ?? false) { logger.error("unreadable project lastOpenedAt; treating the project as never opened") }
            lastOpenedAt = nil
        }
        isShared = (try? c.decodeIfPresent(Bool.self, forKey: .isShared)) ?? false
        if let decoded = try? c.decodeIfPresent(Date.self, forKey: .modifiedAt) {
            modifiedAt = decoded
        } else {
            if c.contains(.modifiedAt), !((try? c.decodeNil(forKey: .modifiedAt)) ?? false) { logger.error("unreadable project modifiedAt; treating the definition as undated") }
            modifiedAt = nil
        }
        if let decoded = try? c.decodeIfPresent(TerminalBackgroundSettings.self, forKey: .background) {
            background = decoded
        } else {
            if c.contains(.background), !((try? c.decodeNil(forKey: .background)) ?? false) { logger.error("unreadable project background; following Settings") }
            background = nil
        }
        sharedImage = (try? c.decodeIfPresent(ProjectSharedImage.self, forKey: .sharedImage)) ?? nil
        if let decoded = try? c.decodeIfPresent(ThemePair.self, forKey: .theme) {
            theme = decoded.normalized
        } else {
            if c.contains(.theme), !((try? c.decodeNil(forKey: .theme)) ?? false) { logger.error("unreadable project theme; following Settings") }
            theme = nil
        }
        notificationsMuted = (try? c.decodeIfPresent(Bool.self, forKey: .notificationsMuted)) ?? false
        paneListExpanded = (try? c.decodeIfPresent(Bool.self, forKey: .paneListExpanded)) ?? false
    }
}
