// HyperlinkOpener.swift

import AppKit
import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "HyperlinkOpener")

enum HyperlinkOpener {
    static let allowedSchemes: Set<String> = ["http", "https", "file", "mailto", "ftp"]

    static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            logger.warning("rejected unparseable hyperlink: \(urlString, privacy: .public)")
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        guard allowedSchemes.contains(scheme) else {
            logger.warning("rejected hyperlink with disallowed scheme \(scheme, privacy: .public): \(urlString, privacy: .public)")
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func copyToPasteboard(_ urlString: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urlString, forType: .string)
    }
}
