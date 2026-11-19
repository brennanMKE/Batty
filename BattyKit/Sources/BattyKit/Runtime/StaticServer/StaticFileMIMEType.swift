// StaticFileMIMEType.swift

import Foundation

/// A fixed table rather than `UTType`, so the answer is the same on every
/// macOS version.
public nonisolated enum StaticFileMIMEType {
    static let table: [String: String] = [
        "html": "text/html", "htm": "text/html",
        "css": "text/css",
        "js": "text/javascript", "mjs": "text/javascript",
        "json": "application/json", "map": "application/json",
        "svg": "image/svg+xml",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "avif": "image/avif", "ico": "image/x-icon",
        "txt": "text/plain", "md": "text/plain",
        "xml": "application/xml", "csv": "text/csv",
        "pdf": "application/pdf",
        "wasm": "application/wasm",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
        "mp4": "video/mp4", "webm": "video/webm", "mp3": "audio/mpeg", "wav": "audio/wav",
    ]

    static let textual: Set<String> = [
        "text/html", "text/css", "text/javascript", "application/json", "image/svg+xml",
        "text/plain", "application/xml", "text/csv",
    ]

    public static func mimeType(forPathExtension ext: String) -> String {
        guard let type = table[ext.lowercased()] else { return "application/octet-stream" }
        return textual.contains(type) ? type + "; charset=utf-8" : type
    }

    public static func isHTML(_ mimeType: String) -> Bool {
        mimeType.hasPrefix("text/html")
    }
}
