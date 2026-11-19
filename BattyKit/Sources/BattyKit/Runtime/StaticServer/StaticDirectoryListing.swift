// StaticDirectoryListing.swift

import Foundation

public nonisolated enum StaticDirectoryListing {
    public static func html(for directory: URL, relativePath: String) -> Data {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var rows = ""
        for name in names {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path, isDirectory: &isDirectory)
            let suffix = isDirectory.boolValue ? "/" : ""
            let href = StaticFilePathResolver.encodeSegment(name) + suffix
            rows += "<li><a href=\"\(escape(href))\">\(escape(name + suffix))</a></li>\n"
        }
        let title = escape(relativePath)
        let page = """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(title)</title></head>
        <body><h1>\(title)</h1>
        <ul>
        \(rows)</ul>
        </body></html>

        """
        return Data(page.utf8)
    }

    public static func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }
}
