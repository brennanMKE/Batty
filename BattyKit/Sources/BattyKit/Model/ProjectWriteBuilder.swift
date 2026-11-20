// ProjectWriteBuilder.swift

import BattyXPCCore
import Foundation

struct ProjectWriteError: Error, Equatable {
    let message: String

    init(_ message: String) { self.message = message }
}

/// Applies the scalar fields of a CLI `project create`/`edit` request to a
/// Project. A field the request leaves nil keeps the base's value.
enum ProjectWriteBuilder {
    /// `imagePath` nil leaves the Project's image alone; `.some(nil)` clears
    /// the background; a path is a newly picked image.
    static func apply(_ request: ProjectWriteRequest, to base: Project, imagePath: String??) throws(ProjectWriteError) -> Project {
        var project = base
        if let name = request.name {
            project.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let root = request.rootPath {
            guard root.hasPrefix("/") else { throw ProjectWriteError("path: must be an absolute path") }
            project.rootPath = Project.standardizedRoot(root)
        }
        if let name = request.color {
            guard let color = SessionColor.allCases.first(where: { "\($0)" == name.lowercased() }) else {
                throw ProjectWriteError("color: unknown color \"\(name)\"; use one of \(ProjectVocabulary.colorNames.joined(separator: ", "))")
            }
            project.color = color
            project.customColorHex = nil
        }
        if let hex = request.colorHex {
            guard let normalized = ProjectAppearance.normalizedHex(hex) else {
                throw ProjectWriteError("color-hex: \"\(hex)\" is not a #RRGGBB color")
            }
            let resolved = ProjectAppearance.resolve(color: project.color, customHex: normalized)
            project.color = resolved.color
            project.customColorHex = resolved.customHex
        }
        if let name = request.symbol {
            guard let symbol = ProjectSymbol(rawValue: name) else {
                throw ProjectWriteError("symbol: unknown symbol \"\(name)\"; use one of \(ProjectVocabulary.symbolNames.joined(separator: ", ")), or --symbol-name")
            }
            project.symbol = symbol
            project.customSymbolName = nil
        }
        if let name = request.symbolName {
            let resolved = ProjectAppearance.resolve(symbol: .folder, customName: name)
            project.symbol = resolved.symbol
            project.customSymbolName = resolved.customName
        }
        if request.clearTheme {
            project.theme = nil
        } else if request.themeDark != nil || request.themeLight != nil {
            project.theme = ThemePair(dark: request.themeDark ?? project.theme?.dark, light: request.themeLight ?? project.theme?.light).normalized
        }
        if case .preset(let name) = request.layout {
            guard let preset = PaneLayout(rawValue: name) else {
                throw ProjectWriteError("preset: unknown preset \"\(name)\"; use one of \(ProjectVocabulary.presetNames.joined(separator: ", "))")
            }
            project.layout = .preset(preset)
        }
        project.background = try background(request, current: project.background, imagePath: imagePath)
        if project.background?.imagePath == nil { project.sharedImage = nil }
        return project
    }

    private static func background(_ request: ProjectWriteRequest, current: TerminalBackgroundSettings?, imagePath: String??) throws(ProjectWriteError) -> TerminalBackgroundSettings? {
        for (flag, percent) in [("opacity", request.imageOpacityPercent), ("terminal-opacity", request.terminalOpacityPercent)] {
            if let percent, !(0...100).contains(percent) { throw ProjectWriteError("\(flag): must be from 0 to 100") }
        }
        var value = current
        switch imagePath {
        case .none:
            break
        case .some(.none):
            if request.imageOpacityPercent != nil || request.terminalOpacityPercent != nil {
                throw ProjectWriteError("background: --no-background can't take an opacity")
            }
            return nil
        case .some(.some(let path)):
            value = (value ?? TerminalBackgroundSettings(imagePath: nil)).pickingImage(path: path)
        }
        if let percent = request.imageOpacityPercent {
            guard let current = value, current.imagePath != nil else { throw ProjectWriteError("opacity: --opacity needs an image") }
            value = current.withImageOpacity(Double(percent) / 100)
        }
        if let percent = request.terminalOpacityPercent {
            value = (value ?? TerminalBackgroundSettings(imagePath: nil)).withTerminalOpacity(Double(percent) / 100)
        }
        return value
    }

    /// Each command goes to the next terminal Tab in slot order.
    static func assign(startupCommands: [String], to layout: ProjectLayout) throws(ProjectWriteError) -> ProjectLayout {
        let tabs = layout.panes.filter { $0.kind == .terminal }.reduce(0) { $0 + $1.tabs.count }
        guard startupCommands.count <= tabs else {
            throw ProjectWriteError("startup-command: \(startupCommands.count) startup commands but only \(tabs) terminal Tabs")
        }
        var remaining = startupCommands[...]
        var result = layout
        result.root = layout.root.mappingPanes { _, pane in
            guard pane.kind == .terminal else { return pane }
            var edited = pane
            for index in edited.tabs.indices {
                guard let command = remaining.popFirst() else { break }
                edited.tabs[index].startupCommand = command
            }
            return edited
        }
        return result
    }
}

/// A CLI verb's outcome: a reply, or the message the CLI prints and exits 4 on.
enum CLIOutcome<Reply> {
    case success(Reply)
    case failure(String)
}
