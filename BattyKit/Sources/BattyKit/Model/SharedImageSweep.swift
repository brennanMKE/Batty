// SharedImageSweep.swift

import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "SharedImageSweep")

/// Decides which files in the shared folder have gone unnamed long enough to
/// delete. Folder dates in iCloud Drive aren't used: a device-local ledger
/// records when each digest was first seen unnamed. Deleting too early costs a
/// re-upload, as long as one Mac still holds the image.
nonisolated enum SharedImageSweep {
    static let gracePeriod: TimeInterval = 30 * 24 * 60 * 60
    static let ledgerFileName = "shared-image-sweep.json"

    /// A digest named again leaves the ledger, and so starts over if it is
    /// unnamed later. Names that aren't digests are never touched.
    static func decide(
        listed: [String],
        named: Set<String>,
        ledger: [String: Date],
        now: Date
    ) -> (delete: [String], ledger: [String: Date]) {
        var delete: [String] = []
        var updated: [String: Date] = [:]
        for digest in listed where TerminalBackgroundImageImporter.isDigest(digest) && !named.contains(digest) {
            let firstSeen = ledger[digest] ?? now
            if now.timeIntervalSince(firstSeen) >= gracePeriod {
                delete.append(digest)
            } else {
                updated[digest] = firstSeen
            }
        }
        return (delete.sorted(), updated)
    }

    static func readLedger(at url: URL) -> [String: Date] {
        guard let data = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder().decode([String: Date].self, from: data)
        else { return [:] }
        return ledger
    }

    static func writeLedger(_ ledger: [String: Date], to url: URL) {
        do {
            try JSONEncoder().encode(ledger).write(to: url, options: [.atomic])
        } catch {
            logger.error("could not save the shared image ledger: \(error.localizedDescription, privacy: .public)")
        }
    }
}
