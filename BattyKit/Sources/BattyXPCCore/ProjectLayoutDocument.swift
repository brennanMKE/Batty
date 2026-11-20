// ProjectLayoutDocument.swift

import Foundation

/// The layout an agent gives `batty project create`/`edit` with `--layout`
/// or `--layout-json`. A small, stable contract rather than the
/// `projects.json` encoding, which decodes leniently and carries device
/// paths. Decoding is strict: an unknown key is an error naming its path,
/// so a typo never saves silently. The app maps it onto `ProjectLayout`.
public nonisolated struct ProjectLayoutDocument: Codable, Sendable, Equatable {
    public var preset: String?
    public var panes: [Pane]?
    public var root: Node?
    public var focusedPane: Int?

    public init(preset: String? = nil, panes: [Pane]? = nil, root: Node? = nil, focusedPane: Int? = nil) {
        self.preset = preset
        self.panes = panes
        self.root = root
        self.focusedPane = focusedPane
    }

    public indirect enum Node: Codable, Sendable, Equatable {
        /// `{"split": "horizontal"|"vertical", "children": [...]}`
        case split(direction: String, children: [Node])
        /// Any object with `kind`.
        case pane(Pane)

        private enum SplitKeys: String, CodingKey { case split, children }

        public init(from decoder: Decoder) throws {
            let keys = try ProjectLayoutDocument.keys(of: decoder)
            if keys.contains("split") {
                try ProjectLayoutDocument.rejectUnknownKeys(keys, allowed: SplitKeys.self, decoder: decoder)
                let c = try decoder.container(keyedBy: SplitKeys.self)
                let children = try c.decode([Node].self, forKey: .children)
                guard children.count >= 2 else {
                    throw ProjectLayoutDocumentError.splitNeedsTwoChildren(path: ProjectLayoutDocument.path(decoder.codingPath))
                }
                self = .split(direction: try c.decode(String.self, forKey: .split), children: children)
            } else {
                self = .pane(try Pane(from: decoder))
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .split(let direction, let children):
                var c = encoder.container(keyedBy: SplitKeys.self)
                try c.encode(direction, forKey: .split)
                try c.encode(children, forKey: .children)
            case .pane(let pane):
                try pane.encode(to: encoder)
            }
        }
    }

    public struct Pane: Codable, Sendable, Equatable {
        public var kind: String
        public var tabs: [Tab]?
        public var repository: String?
        public var background: Background?
        public var hidden: Bool?
        public var activeTab: Int?

        public init(kind: String, tabs: [Tab]? = nil, repository: String? = nil, background: Background? = nil, hidden: Bool? = nil, activeTab: Int? = nil) {
            self.kind = kind
            self.tabs = tabs
            self.repository = repository
            self.background = background
            self.hidden = hidden
            self.activeTab = activeTab
        }

        private enum CodingKeys: String, CodingKey { case kind, tabs, repository, background, hidden, activeTab }

        public init(from decoder: Decoder) throws {
            try ProjectLayoutDocument.rejectUnknownKeys(ProjectLayoutDocument.keys(of: decoder), allowed: CodingKeys.self, decoder: decoder)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(String.self, forKey: .kind)
            tabs = try c.decodeIfPresent([Tab].self, forKey: .tabs)
            repository = try c.decodeIfPresent(String.self, forKey: .repository)
            background = try c.decodeIfPresent(Background.self, forKey: .background)
            hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden)
            activeTab = try c.decodeIfPresent(Int.self, forKey: .activeTab)
        }
    }

    public struct Tab: Codable, Sendable, Equatable {
        public var title: String?
        /// Relative to the Project root.
        public var cwd: String?
        public var command: String?
        public var background: Background?

        public init(title: String? = nil, cwd: String? = nil, command: String? = nil, background: Background? = nil) {
            self.title = title
            self.cwd = cwd
            self.command = command
            self.background = background
        }

        private enum CodingKeys: String, CodingKey { case title, cwd, command, background }

        public init(from decoder: Decoder) throws {
            try ProjectLayoutDocument.rejectUnknownKeys(ProjectLayoutDocument.keys(of: decoder), allowed: CodingKeys.self, decoder: decoder)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
            command = try c.decodeIfPresent(String.self, forKey: .command)
            background = try c.decodeIfPresent(Background.self, forKey: .background)
        }
    }

    /// One image source (`id` a Background Sets full URL, `set`+`image`,
    /// `digest` a My Images image, or `file`), plus opacities in percent.
    public struct Background: Codable, Sendable, Hashable {
        public var id: String?
        public var set: String?
        public var image: String?
        public var digest: String?
        public var file: String?
        public var opacity: Int?
        public var terminalOpacity: Int?

        public init(id: String? = nil, set: String? = nil, image: String? = nil, digest: String? = nil, file: String? = nil, opacity: Int? = nil, terminalOpacity: Int? = nil) {
            self.id = id
            self.set = set
            self.image = image
            self.digest = digest
            self.file = file
            self.opacity = opacity
            self.terminalOpacity = terminalOpacity
        }

        private enum CodingKeys: String, CodingKey { case id, set, image, digest, file, opacity, terminalOpacity }

        public init(from decoder: Decoder) throws {
            try ProjectLayoutDocument.rejectUnknownKeys(ProjectLayoutDocument.keys(of: decoder), allowed: CodingKeys.self, decoder: decoder)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id)
            set = try c.decodeIfPresent(String.self, forKey: .set)
            image = try c.decodeIfPresent(String.self, forKey: .image)
            digest = try c.decodeIfPresent(String.self, forKey: .digest)
            file = try c.decodeIfPresent(String.self, forKey: .file)
            opacity = try c.decodeIfPresent(Int.self, forKey: .opacity)
            terminalOpacity = try c.decodeIfPresent(Int.self, forKey: .terminalOpacity)
        }
    }

    private enum CodingKeys: String, CodingKey { case preset, panes, root, focusedPane }

    public init(from decoder: Decoder) throws {
        try Self.rejectUnknownKeys(Self.keys(of: decoder), allowed: CodingKeys.self, decoder: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preset = try c.decodeIfPresent(String.self, forKey: .preset)
        panes = try c.decodeIfPresent([Pane].self, forKey: .panes)
        root = try c.decodeIfPresent(Node.self, forKey: .root)
        focusedPane = try c.decodeIfPresent(Int.self, forKey: .focusedPane)
        if root != nil {
            if panes != nil { throw ProjectLayoutDocumentError.panesWithRoot }
            if preset != nil { throw ProjectLayoutDocumentError.presetAndRoot }
        } else if preset == nil {
            throw panes == nil ? ProjectLayoutDocumentError.presetAndRoot : ProjectLayoutDocumentError.panesWithoutPreset
        }
    }

    public static func parse(_ data: Data) throws(ProjectLayoutDocumentError) -> ProjectLayoutDocument {
        do {
            return try JSONDecoder().decode(ProjectLayoutDocument.self, from: data)
        } catch let error as ProjectLayoutDocumentError {
            throw error
        } catch let DecodingError.typeMismatch(_, context) {
            throw .wrongType(path: path(context.codingPath))
        } catch let DecodingError.valueNotFound(_, context) {
            throw .wrongType(path: path(context.codingPath))
        } catch let DecodingError.keyNotFound(key, context) {
            throw .missingKey(path: path(context.codingPath + [key]))
        } catch {
            throw .invalidJSON
        }
    }

    /// Makes every relative `background.file` absolute against `cwd`, the
    /// caller's directory, so the app never sees a relative path.
    public func resolvingFiles(against cwd: String) -> ProjectLayoutDocument {
        func fix(_ background: Background?) -> Background? {
            guard var background, let file = background.file else { return background }
            background.file = Self.absolute(file, cwd: cwd)
            return background
        }
        func fix(_ pane: Pane) -> Pane {
            var pane = pane
            pane.background = fix(pane.background)
            pane.tabs = pane.tabs?.map { tab in
                var tab = tab
                tab.background = fix(tab.background)
                return tab
            }
            return pane
        }
        func fix(_ node: Node) -> Node {
            switch node {
            case .split(let direction, let children): .split(direction: direction, children: children.map(fix))
            case .pane(let pane): .pane(fix(pane))
            }
        }
        var copy = self
        copy.panes = panes?.map(fix)
        copy.root = root.map(fix)
        return copy
    }

    /// `path` made absolute against `cwd` (with `~` expanded) and standardized.
    public static func absolute(_ path: String, cwd: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let joined = expanded.hasPrefix("/") ? expanded : (cwd as NSString).appendingPathComponent(expanded)
        return (joined as NSString).standardizingPath
    }

    // MARK: - Strict decoding

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    fileprivate static func keys(of decoder: Decoder) throws -> [String] {
        try decoder.container(keyedBy: DynamicKey.self).allKeys.map(\.stringValue)
    }

    fileprivate static func rejectUnknownKeys<K: CodingKey & RawRepresentable>(_ keys: [String], allowed: K.Type, decoder: Decoder) throws where K.RawValue == String {
        if let unknown = keys.sorted().first(where: { K(rawValue: $0) == nil }) {
            throw ProjectLayoutDocumentError.unknownKey(path: path(decoder.codingPath), key: unknown)
        }
    }

    /// A JSON path such as `panes[1].tabs[0]`, or `layout` at the top.
    public static func path(_ codingPath: [CodingKey]) -> String {
        var result = ""
        for key in codingPath {
            if let index = key.intValue {
                result += "[\(index)]"
            } else {
                result += result.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
        return result.isEmpty ? "layout" : result
    }
}

public nonisolated enum ProjectLayoutDocumentError: Error, Equatable, Sendable {
    case invalidJSON
    case unknownKey(path: String, key: String)
    case wrongType(path: String)
    case missingKey(path: String)
    case presetAndRoot
    case panesWithRoot
    case panesWithoutPreset
    case splitNeedsTwoChildren(path: String)

    public var message: String {
        switch self {
        case .invalidJSON:
            "layout: not valid JSON"
        case .unknownKey(let path, let key):
            "\(path == "layout" ? "" : "\(path).")\(key): unknown key"
        case .wrongType(let path):
            "\(path): wrong type"
        case .missingKey(let path):
            "\(path): missing"
        case .presetAndRoot:
            "layout: give either \"preset\" (with optional \"panes\") or \"root\", not both or neither"
        case .panesWithRoot:
            "layout: \"panes\" goes with \"preset\", not \"root\""
        case .panesWithoutPreset:
            "layout: \"panes\" needs a \"preset\""
        case .splitNeedsTwoChildren(let path):
            "\(path).children: a split needs at least two children"
        }
    }
}

/// Names the `batty` CLI offers for BattyKit enums it cannot import. A
/// drift test pins each list to its enum.
public nonisolated enum ProjectVocabulary {
    public static let presetNames = [
        "singlePane", "horizontalSplit", "verticalSplit", "threeColumns", "threeRows",
        "mainLeftTwoRight", "mainRightTwoLeft", "mainTopTwoBottom", "mainBottomTwoTop", "twoByTwoGrid",
    ]
    public static let colorNames = ["blue", "orange", "green", "pink", "teal", "red", "violet", "amber", "cyan", "brown"]
    public static let symbolNames = [
        "folder", "terminal", "code", "hammer", "tools", "package", "branch", "checklist", "extension", "macApp",
        "iPhoneApp", "web", "server", "cloud", "network", "security", "link", "qrCode", "chip", "wireless",
        "light", "home", "art", "grid", "craft", "video", "game", "document", "learning", "chart",
        "calendar", "social", "community", "ai", "model", "map", "music",
    ]
}
