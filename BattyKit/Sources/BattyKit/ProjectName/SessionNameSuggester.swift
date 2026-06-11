// SessionNameSuggester.swift

import Foundation
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "SessionNameSuggester")

/// Produces a short, human-friendly session name for a working directory
/// when the deterministic chain (name cache, project rules) found nothing.
/// Returning `nil` means "no good name" — the caller keeps the default
/// `Session N` title. Implementations must never throw to the caller.
public protocol SessionNameSuggesting: AnyObject {
    func suggestName(forPath path: String) async -> String?
}

/// Shared validation for model-suggested session names. A suggestion only
/// reaches a session title if it survives `sanitize` — everything else
/// (NONE, empty, too long, punctuation-heavy) collapses to `nil`.
public enum SessionNameSuggestion {
    public static let maxWordCount = 4
    public static let maxLength = 40

    private static let allowedScalars = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: " -_"))

    public static func sanitize(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`\u{201C}\u{201D}\u{2018}\u{2019}"))
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard name.uppercased() != "NONE" else { return nil }
        guard name.count <= maxLength else { return nil }
        guard name.unicodeScalars.allSatisfy({ allowedScalars.contains($0) }) else { return nil }
        let words = name.split(separator: " ")
        guard (1...maxWordCount).contains(words.count) else { return nil }
        return name
    }
}

/// On-device FoundationModels-backed suggester. Requires macOS 26+ and an
/// available system language model (Apple Intelligence enabled, model
/// downloaded). On every other configuration `suggestName` returns `nil`
/// and the auto-naming chain behaves exactly as before this feature.
public final class FoundationModelsNameSuggester: SessionNameSuggesting {
    /// Top-level entry cap for the prompt's folder listing.
    static let entryLimit = 20

    static let instructions = """
        You name terminal sessions after the folder the user is working in. \
        Reply with only 2-4 words, no punctuation, no quotes. \
        Reply NONE if the folder path and contents give no meaningful signal \
        (temporary folders, untitled folders, random hashes).
        """

    /// Returns a live suggester when the OS can possibly host the model,
    /// `nil` otherwise. Model availability (Apple Intelligence toggle,
    /// download state) is re-checked on every call, not just here.
    public static func makeIfAvailable() -> SessionNameSuggesting? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return FoundationModelsNameSuggester()
        }
        #endif
        return nil
    }

    public init() {}

    public func suggestName(forPath path: String) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return nil }
        guard case .available = SystemLanguageModel.default.availability else {
            logger.info("system language model unavailable; skipping AI session naming")
            return nil
        }
        let prompt = Self.prompt(forPath: path, entries: Self.topLevelEntries(atPath: path))
        do {
            // A dedicated session per request keeps the naming instructions
            // tight and avoids sharing context with any other model use.
            let session = LanguageModelSession(instructions: Self.instructions)
            let response = try await session.respond(to: prompt)
            let raw = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.info("suggestion for \(path, privacy: .public): '\(raw, privacy: .public)'")
            return raw.isEmpty ? nil : raw
        } catch is CancellationError {
            return nil
        } catch {
            logger.error("session name suggestion failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        #else
        return nil
        #endif
    }

    static func topLevelEntries(atPath path: String, limit: Int = FoundationModelsNameSuggester.entryLimit) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        return Array(entries.filter { !$0.hasPrefix(".") }.sorted().prefix(limit))
    }

    static func prompt(forPath path: String, entries: [String]) -> String {
        var lines = ["Folder path: \(path)"]
        if !entries.isEmpty {
            lines.append("Top-level contents: \(entries.joined(separator: ", "))")
        }
        lines.append("Session name:")
        return lines.joined(separator: "\n")
    }
}
