// Theme.swift

import Foundation

struct ThemeColor: Codable, Sendable, Hashable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") {
            s.removeFirst()
        } else if s.hasPrefix("0x") || s.hasPrefix("0X") {
            s.removeFirst(2)
        }
        guard s.count == 6 else { return nil }
        guard
            let r = UInt8(s.prefix(2), radix: 16),
            let g = UInt8(s.dropFirst(2).prefix(2), radix: 16),
            let b = UInt8(s.dropFirst(4).prefix(2), radix: 16)
        else { return nil }
        self.red = Double(r) / 255.0
        self.green = Double(g) / 255.0
        self.blue = Double(b) / 255.0
    }
}

struct Theme: Codable, Sendable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var foreground: ThemeColor
    var background: ThemeColor
    var cursor: ThemeColor?
    var selectionForeground: ThemeColor?
    var selectionBackground: ThemeColor?
    var palette: [ThemeColor]
}

enum ThemeParseError: Error, Equatable, Sendable {
    case missingForeground
    case missingBackground
    case missingPaletteEntry(Int)
    case invalidColor(key: String, value: String)
}

enum ThemeParser {

    static func parse(_ source: String, name: String) throws -> Theme {
        var foreground: ThemeColor?
        var background: ThemeColor?
        var cursor: ThemeColor?
        var selectionForeground: ThemeColor?
        var selectionBackground: ThemeColor?
        var paletteByIndex: [Int: ThemeColor] = [:]

        for rawLine in source.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            guard let equalsIdx = line.firstIndex(of: "=") else { continue }
            let key = line[..<equalsIdx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equalsIdx)...].trimmingCharacters(in: .whitespaces)

            switch key {
            case "foreground":
                guard let c = ThemeColor(hex: value) else {
                    throw ThemeParseError.invalidColor(key: key, value: value)
                }
                foreground = c
            case "background":
                guard let c = ThemeColor(hex: value) else {
                    throw ThemeParseError.invalidColor(key: key, value: value)
                }
                background = c
            case "cursor-color":
                guard let c = ThemeColor(hex: value) else {
                    throw ThemeParseError.invalidColor(key: key, value: value)
                }
                cursor = c
            case "selection-foreground":
                guard let c = ThemeColor(hex: value) else {
                    throw ThemeParseError.invalidColor(key: key, value: value)
                }
                selectionForeground = c
            case "selection-background":
                guard let c = ThemeColor(hex: value) else {
                    throw ThemeParseError.invalidColor(key: key, value: value)
                }
                selectionBackground = c
            case "palette":
                guard let paletteEqIdx = value.firstIndex(of: "=") else { continue }
                let indexStr = value[..<paletteEqIdx].trimmingCharacters(in: .whitespaces)
                let hexStr = value[value.index(after: paletteEqIdx)...].trimmingCharacters(in: .whitespaces)
                guard
                    let idx = Int(indexStr),
                    (0..<16).contains(idx),
                    let c = ThemeColor(hex: hexStr)
                else {
                    throw ThemeParseError.invalidColor(key: "palette[\(indexStr)]", value: hexStr)
                }
                paletteByIndex[idx] = c
            default:
                continue
            }
        }

        guard let fg = foreground else { throw ThemeParseError.missingForeground }
        guard let bg = background else { throw ThemeParseError.missingBackground }

        var palette: [ThemeColor] = []
        palette.reserveCapacity(16)
        for i in 0..<16 {
            guard let c = paletteByIndex[i] else {
                throw ThemeParseError.missingPaletteEntry(i)
            }
            palette.append(c)
        }

        return Theme(
            name: name,
            foreground: fg,
            background: bg,
            cursor: cursor,
            selectionForeground: selectionForeground,
            selectionBackground: selectionBackground,
            palette: palette
        )
    }
}

enum ThemeStore {

    static func discoverAll(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil
    ) -> [Theme] {
        var byName: [String: Theme] = [:]

        for url in bundleThemeURLs(bundle: bundle, fileManager: fileManager) {
            ingest(url, into: &byName, fileManager: fileManager)
        }
        for url in userThemeURLs(fileManager: fileManager, homeDirectory: homeDirectory) {
            ingest(url, into: &byName, fileManager: fileManager)
        }

        for builtin in builtInThemes where byName[builtin.name] == nil {
            byName[builtin.name] = builtin
        }

        return byName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func ingest(
        _ url: URL,
        into byName: inout [String: Theme],
        fileManager: FileManager
    ) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return }
        let name = url.deletingPathExtension().lastPathComponent
        guard let theme = try? ThemeParser.parse(source, name: name) else { return }
        if byName[theme.name] == nil {
            byName[theme.name] = theme
        }
    }

    private static func bundleThemeURLs(bundle: Bundle, fileManager: FileManager) -> [URL] {
        guard let resourcesURL = bundle.resourceURL else { return [] }
        let dir = resourcesURL.appendingPathComponent("Themes", isDirectory: true)
        guard fileManager.fileExists(atPath: dir.path) else { return [] }
        return (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "ghostty" || $0.pathExtension.isEmpty } ?? []
    }

    private static func userThemeURLs(fileManager: FileManager, homeDirectory: URL?) -> [URL] {
        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".config/ghostty/themes", isDirectory: true)
        guard fileManager.fileExists(atPath: dir.path) else { return [] }
        return (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "ghostty" || $0.pathExtension.isEmpty } ?? []
    }
}

extension ThemeStore {
    static let builtInThemes: [Theme] = [
        Theme(
            name: "Batty Dark",
            foreground: ThemeColor(hex: "#c5c8c6")!,
            background: ThemeColor(hex: "#1d1f21")!,
            cursor: ThemeColor(hex: "#c5c8c6")!,
            selectionForeground: nil,
            selectionBackground: ThemeColor(hex: "#373b41")!,
            palette: [
                ThemeColor(hex: "#1d1f21")!, ThemeColor(hex: "#cc6666")!,
                ThemeColor(hex: "#b5bd68")!, ThemeColor(hex: "#f0c674")!,
                ThemeColor(hex: "#81a2be")!, ThemeColor(hex: "#b294bb")!,
                ThemeColor(hex: "#8abeb7")!, ThemeColor(hex: "#c5c8c6")!,
                ThemeColor(hex: "#666666")!, ThemeColor(hex: "#d54e53")!,
                ThemeColor(hex: "#b9ca4a")!, ThemeColor(hex: "#e7c547")!,
                ThemeColor(hex: "#7aa6da")!, ThemeColor(hex: "#c397d8")!,
                ThemeColor(hex: "#70c0b1")!, ThemeColor(hex: "#eaeaea")!,
            ]
        ),
        Theme(
            name: "Batty Light",
            foreground: ThemeColor(hex: "#383a42")!,
            background: ThemeColor(hex: "#fafafa")!,
            cursor: ThemeColor(hex: "#383a42")!,
            selectionForeground: nil,
            selectionBackground: ThemeColor(hex: "#e5e5e6")!,
            palette: [
                ThemeColor(hex: "#fafafa")!, ThemeColor(hex: "#e45649")!,
                ThemeColor(hex: "#50a14f")!, ThemeColor(hex: "#c18401")!,
                ThemeColor(hex: "#0184bc")!, ThemeColor(hex: "#a626a4")!,
                ThemeColor(hex: "#0997b3")!, ThemeColor(hex: "#383a42")!,
                ThemeColor(hex: "#a0a1a7")!, ThemeColor(hex: "#e45649")!,
                ThemeColor(hex: "#50a14f")!, ThemeColor(hex: "#c18401")!,
                ThemeColor(hex: "#0184bc")!, ThemeColor(hex: "#a626a4")!,
                ThemeColor(hex: "#0997b3")!, ThemeColor(hex: "#090a0b")!,
            ]
        ),
        Theme(
            name: "Solarized Dark",
            foreground: ThemeColor(hex: "#839496")!,
            background: ThemeColor(hex: "#002b36")!,
            cursor: ThemeColor(hex: "#93a1a1")!,
            selectionForeground: nil,
            selectionBackground: ThemeColor(hex: "#073642")!,
            palette: [
                ThemeColor(hex: "#073642")!, ThemeColor(hex: "#dc322f")!,
                ThemeColor(hex: "#859900")!, ThemeColor(hex: "#b58900")!,
                ThemeColor(hex: "#268bd2")!, ThemeColor(hex: "#d33682")!,
                ThemeColor(hex: "#2aa198")!, ThemeColor(hex: "#eee8d5")!,
                ThemeColor(hex: "#002b36")!, ThemeColor(hex: "#cb4b16")!,
                ThemeColor(hex: "#586e75")!, ThemeColor(hex: "#657b83")!,
                ThemeColor(hex: "#839496")!, ThemeColor(hex: "#6c71c4")!,
                ThemeColor(hex: "#93a1a1")!, ThemeColor(hex: "#fdf6e3")!,
            ]
        ),
        Theme(
            name: "Dracula",
            foreground: ThemeColor(hex: "#f8f8f2")!,
            background: ThemeColor(hex: "#282a36")!,
            cursor: ThemeColor(hex: "#f8f8f2")!,
            selectionForeground: nil,
            selectionBackground: ThemeColor(hex: "#44475a")!,
            palette: [
                ThemeColor(hex: "#21222c")!, ThemeColor(hex: "#ff5555")!,
                ThemeColor(hex: "#50fa7b")!, ThemeColor(hex: "#f1fa8c")!,
                ThemeColor(hex: "#bd93f9")!, ThemeColor(hex: "#ff79c6")!,
                ThemeColor(hex: "#8be9fd")!, ThemeColor(hex: "#f8f8f2")!,
                ThemeColor(hex: "#6272a4")!, ThemeColor(hex: "#ff6e6e")!,
                ThemeColor(hex: "#69ff94")!, ThemeColor(hex: "#ffffa5")!,
                ThemeColor(hex: "#d6acff")!, ThemeColor(hex: "#ff92df")!,
                ThemeColor(hex: "#a4ffff")!, ThemeColor(hex: "#ffffff")!,
            ]
        ),
    ]
}
