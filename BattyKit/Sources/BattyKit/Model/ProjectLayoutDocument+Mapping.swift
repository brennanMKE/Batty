// ProjectLayoutDocument+Mapping.swift

import BattyXPCCore
import Foundation

/// One image a CLI write names, before it is fetched or copied.
enum ProjectBackgroundReference: Hashable, Sendable {
    case hostedID(String)
    case hosted(set: String, title: String)
    case myImage(digest: String)
    case file(String)
}

/// A referenced image once it is in the Project background folder.
struct ResolvedProjectImage: Equatable, Sendable {
    let path: String
    let image: ProjectTabImage?
}

struct ProjectLayoutMappingError: Error, Equatable {
    let path: String
    let problem: String

    var message: String { "\(path): \(problem)" }
}

extension ProjectLayoutDocument.Background {
    /// The one image source, or nil when there is none or more than one.
    var reference: ProjectBackgroundReference? {
        var found: [ProjectBackgroundReference] = []
        if let id { found.append(.hostedID(id)) }
        if set != nil || image != nil { found.append(.hosted(set: set ?? "", title: image ?? "")) }
        if let digest { found.append(.myImage(digest: digest)) }
        if let file { found.append(.file(file)) }
        return found.count == 1 ? found[0] : nil
    }

    fileprivate var sourceCount: Int {
        [id != nil, set != nil || image != nil, digest != nil, file != nil].filter { $0 }.count
    }
}

extension ProjectLayoutDocument {
    /// Every Pane and Tab image the document names.
    func imageReferences() -> [ProjectBackgroundReference] {
        var result: [ProjectBackgroundReference] = []
        for pane in leaves().map(\.pane) {
            if let ref = pane.background?.reference, !result.contains(ref) { result.append(ref) }
            for tab in pane.tabs ?? [] {
                if let ref = tab.background?.reference, !result.contains(ref) { result.append(ref) }
            }
        }
        return result
    }

    /// Structure only: everything `makeLayout` checks except the images.
    func check() throws(ProjectLayoutMappingError) {
        _ = try makeLayout(images: nil)
    }

    /// `images` nil checks structure without resolved images.
    func makeLayout(images: [ProjectBackgroundReference: ResolvedProjectImage]?) throws(ProjectLayoutMappingError) -> ProjectLayout {
        let preset: PaneLayout?
        let root: ProjectLayoutNode
        if let name = self.preset {
            guard let value = PaneLayout(rawValue: name) else {
                throw ProjectLayoutMappingError(path: "preset", problem: "unknown preset \"\(name)\"; use one of \(ProjectVocabulary.presetNames.joined(separator: ", "))")
            }
            preset = value
            let skeleton = ProjectLayout.preset(value)
            if let panes {
                guard panes.count == skeleton.paneCount else {
                    throw ProjectLayoutMappingError(path: "panes", problem: "\(name) has \(skeleton.paneCount) Panes; got \(panes.count)")
                }
                var mapped: [ProjectPane] = []
                for (index, pane) in panes.enumerated() {
                    mapped.append(try Self.map(pane, path: "panes[\(index)]", images: images))
                }
                root = skeleton.root.withPanes(mapped)
            } else {
                root = skeleton.root
            }
        } else if let node = self.root {
            preset = nil
            root = try Self.map(node, path: "root", images: images)
        } else {
            throw ProjectLayoutMappingError(path: "layout", problem: "give a preset or a root")
        }
        let count = root.panes.count
        if let focusedPane, !(0..<count).contains(focusedPane) {
            throw ProjectLayoutMappingError(path: "focusedPane", problem: "must be from 0 to \(count - 1)")
        }
        return ProjectLayout(root: root, preset: preset, focusedSlot: focusedPane)
    }

    private func leaves() -> [(pane: Pane, path: String)] {
        if let panes { return panes.enumerated().map { ($0.element, "panes[\($0.offset)]") } }
        func walk(_ node: Node, _ path: String) -> [(pane: Pane, path: String)] {
            switch node {
            case .pane(let pane): [(pane, path)]
            case .split(_, let children): children.enumerated().flatMap { walk($0.element, "\(path).children[\($0.offset)]") }
            }
        }
        return root.map { walk($0, "root") } ?? []
    }

    private static func map(_ node: Node, path: String, images: [ProjectBackgroundReference: ResolvedProjectImage]?) throws(ProjectLayoutMappingError) -> ProjectLayoutNode {
        switch node {
        case .pane(let pane):
            return .pane(try map(pane, path: path, images: images))
        case .split(let name, let children):
            guard let direction = SplitDirection(rawValue: name) else {
                throw ProjectLayoutMappingError(path: "\(path).split", problem: "must be \"horizontal\" or \"vertical\"")
            }
            var mapped: [ProjectLayoutNode] = []
            for (index, child) in children.enumerated() {
                mapped.append(try map(child, path: "\(path).children[\(index)]", images: images))
            }
            return .split(direction: direction, children: mapped)
        }
    }

    private static func map(_ pane: Pane, path: String, images: [ProjectBackgroundReference: ResolvedProjectImage]?) throws(ProjectLayoutMappingError) -> ProjectPane {
        guard let kind = PaneContentKind(rawValue: pane.kind) else {
            throw ProjectLayoutMappingError(path: "\(path).kind", problem: "unknown kind \"\(pane.kind)\"; use one of \(PaneContentKind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        if kind != .terminal {
            if pane.tabs != nil { throw ProjectLayoutMappingError(path: "\(path).tabs", problem: "only a terminal Pane has Tabs") }
            if pane.background != nil { throw ProjectLayoutMappingError(path: "\(path).background", problem: "only a terminal Pane has a background") }
            if pane.activeTab != nil { throw ProjectLayoutMappingError(path: "\(path).activeTab", problem: "only a terminal Pane has Tabs") }
        }
        if kind != .gitStatus, pane.repository != nil {
            throw ProjectLayoutMappingError(path: "\(path).repository", problem: "only a git-status Pane has a repository")
        }
        var tabs: [ProjectTab] = []
        for (index, tab) in (pane.tabs ?? []).enumerated() {
            let tabPath = "\(path).tabs[\(index)]"
            let level = try background(tab.background, path: "\(tabPath).background", images: images)
            tabs.append(ProjectTab(title: tab.title, workingDirectory: tab.cwd ?? ".", startupCommand: tab.command, background: level?.settings, image: level?.image))
        }
        if kind == .terminal, pane.tabs?.isEmpty == true {
            throw ProjectLayoutMappingError(path: "\(path).tabs", problem: "needs at least one Tab")
        }
        let tabCount = kind == .terminal ? max(tabs.count, 1) : 0
        if let activeTab = pane.activeTab, !(0..<tabCount).contains(activeTab) {
            throw ProjectLayoutMappingError(path: "\(path).activeTab", problem: "must be from 0 to \(tabCount - 1)")
        }
        let level = try background(pane.background, path: "\(path).background", images: images)
        return ProjectPane(
            kind: kind, tabs: tabs, repositoryPath: kind == .gitStatus ? (pane.repository ?? ".") : nil,
            background: level?.settings, image: level?.image, isHidden: pane.hidden ?? false, activeTab: pane.activeTab)
    }

    private static func background(
        _ value: Background?,
        path: String,
        images: [ProjectBackgroundReference: ResolvedProjectImage]?
    ) throws(ProjectLayoutMappingError) -> (settings: TerminalBackgroundSettings, image: ProjectTabImage?)? {
        guard let value else { return nil }
        for (key, percent) in [("opacity", value.opacity), ("terminalOpacity", value.terminalOpacity)] {
            if let percent, !(0...100).contains(percent) {
                throw ProjectLayoutMappingError(path: "\(path).\(key)", problem: "must be from 0 to 100")
            }
        }
        if value.sourceCount > 1 {
            throw ProjectLayoutMappingError(path: path, problem: "give one of id, set and image, digest or file")
        }
        if value.set != nil, value.image == nil { throw ProjectLayoutMappingError(path: "\(path).image", problem: "set needs image") }
        if value.image != nil, value.set == nil { throw ProjectLayoutMappingError(path: "\(path).set", problem: "image needs set") }
        let terminal = Double(value.terminalOpacity ?? 100) / 100
        guard let reference = value.reference else {
            if value.opacity != nil { throw ProjectLayoutMappingError(path: "\(path).opacity", problem: "needs an image") }
            guard value.terminalOpacity != nil else {
                throw ProjectLayoutMappingError(path: path, problem: "give an image or terminalOpacity")
            }
            return (TerminalBackgroundSettings(imagePath: nil, terminalOpacity: terminal), nil)
        }
        let opacity = value.opacity.map { Double($0) / 100 } ?? TerminalBackgroundSettings.firstImageOpacity
        guard let images else {
            return (TerminalBackgroundSettings(imagePath: "/", imageOpacity: opacity, terminalOpacity: terminal), nil)
        }
        guard let resolved = images[reference] else {
            throw ProjectLayoutMappingError(path: path, problem: "the image was not found")
        }
        return (TerminalBackgroundSettings(imagePath: resolved.path, imageOpacity: opacity, terminalOpacity: terminal), resolved.image)
    }
}
