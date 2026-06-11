// SessionNameSuggester.swift

import Foundation
import OSLog
import os
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

/// Thread-safe single-value box the SetSessionName tool writes into during
/// inference. First-call-wins: if the model calls the tool more than once,
/// the first name sticks and later calls are reported back as ignored —
/// deterministic if the model loops, and the confirmation message
/// discourages further calls.
nonisolated final class SuggestedNameBox: Sendable {
    private let state = OSAllocatedUnfairLock<String?>(initialState: nil)

    init() {}

    /// Returns `true` when this call stored the name, `false` when a
    /// previous call already won.
    @discardableResult
    func set(_ name: String) -> Bool {
        state.withLock { current in
            guard current == nil else { return false }
            current = name
            return true
        }
    }

    var value: String? {
        state.withLock { $0 }
    }
}

/// Availability-independent logic backing the FoundationModels tools, kept
/// separate so it stays unit-testable on machines that can't run the model.
nonisolated enum SessionNameToolSupport {
    static let excerptByteLimit = 4096
    static let unreadableFileMessage = "(not a readable text file)"
    static let unknownFileMessage = "(no such file in the folder listing)"

    /// Returns the beginning of a top-level file, or a short diagnostic
    /// message the model can act on. `allowedNames` is the precomputed set
    /// of top-level entry names shown in the prompt; any `fileName` outside
    /// it is rejected, which rules out path traversal by construction
    /// (directory listings never contain `/`).
    static func readExcerpt(
        fileName: String,
        folderPath: String,
        allowedNames: Set<String>,
        byteLimit: Int = excerptByteLimit
    ) -> String {
        guard allowedNames.contains(fileName) else {
            logger.info("readFile \(fileName, privacy: .public): rejected, not in the folder listing")
            return unknownFileMessage
        }
        let url = URL(fileURLWithPath: folderPath).appendingPathComponent(fileName)
        guard let data = readPrefix(of: url, byteLimit: byteLimit),
              let text = decodeUTF8Prefix(data),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.info("readFile \(fileName, privacy: .public): unreadable, returning fallback")
            return unreadableFileMessage
        }
        logger.info("readFile \(fileName, privacy: .public): read \(data.count) bytes")
        return text
    }

    private static func readPrefix(of url: URL, byteLimit: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: byteLimit), !data.isEmpty else { return nil }
        return data
    }

    /// The byte cap can split a multi-byte UTF-8 sequence; dropping up to
    /// three trailing bytes distinguishes a truncated text file from a
    /// genuinely binary one.
    private static func decodeUTF8Prefix(_ data: Data) -> String? {
        var slice = data[...]
        for _ in 0...3 {
            if let text = String(data: slice, encoding: .utf8) { return text }
            guard slice.count > 1 else { return nil }
            slice = slice.dropLast()
        }
        return nil
    }
}

#if canImport(FoundationModels)

@available(macOS 26.0, *)
nonisolated struct ReadFileTool: Tool {
    let name = "readFile"
    let description = "Read the beginning of one top-level file in the folder to learn what it is about."

    @Generable
    struct Arguments {
        @Guide(description: "Exact file name from the folder listing, e.g. README.md")
        let fileName: String
    }

    let folderPath: String
    let allowedNames: Set<String>

    func call(arguments: Arguments) async throws -> String {
        SessionNameToolSupport.readExcerpt(
            fileName: arguments.fileName,
            folderPath: folderPath,
            allowedNames: allowedNames
        )
    }
}

@available(macOS 26.0, *)
nonisolated struct SetSessionNameTool: Tool {
    let name = "setSessionName"
    let description = "Set the session name. Call at most once, with a short 2-4 word name, no punctuation."

    @Generable
    struct Arguments {
        @Guide(description: "The session name: 2-4 words, no punctuation, no quotes")
        let name: String
    }

    let box: SuggestedNameBox

    func call(arguments: Arguments) async throws -> String {
        if box.set(arguments.name) {
            logger.info("setSessionName '\(arguments.name, privacy: .public)': accepted")
            return "Session name set to \(arguments.name)."
        }
        logger.info("setSessionName '\(arguments.name, privacy: .public)': ignored, a name was already set")
        return "Session name was already set; the first name is kept."
    }
}

#endif

/// On-device FoundationModels-backed suggester. Requires macOS 26+ and an
/// available system language model (Apple Intelligence enabled, model
/// downloaded). On every other configuration `suggestName` returns `nil`
/// and the auto-naming chain behaves exactly as before this feature.
public final class FoundationModelsNameSuggester: SessionNameSuggesting {
    /// Top-level entry cap for the prompt's folder listing.
    static let entryLimit = 20

    static let instructions = """
        You name terminal sessions after the folder the user is working in. \
        You are given the folder path and a listing of its top-level entries. \
        You may call readFile on at most 2-3 promising entries from the \
        listing (README, manifest, or notes files) to learn what the folder \
        contains. Then either call setSessionName exactly once with a short \
        name of 2-4 words and no punctuation, or finish without calling \
        setSessionName if the path and contents give no meaningful signal \
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
        let entries = Self.topLevelEntries(atPath: path)
        logger.info("suggesting name for \(path, privacy: .public) with \(entries.count) top-level entries")
        let box = SuggestedNameBox()
        // A dedicated session per request keeps the naming instructions
        // tight and avoids sharing context with any other model use. The
        // name lands in the box via the tool; the final response text is
        // ignored — finishing without a setSessionName call is the
        // "no good name" outcome.
        let session = LanguageModelSession(
            tools: [
                ReadFileTool(folderPath: path, allowedNames: Set(entries)),
                SetSessionNameTool(box: box),
            ],
            instructions: Self.instructions
        )
        let start = Date()
        do {
            _ = try await session.respond(to: Self.prompt(forPath: path, entries: entries))
        } catch is CancellationError {
            return nil
        } catch {
            logger.error("session name suggestion failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let elapsed = Date().timeIntervalSince(start)
        guard let name = box.value else {
            logger.info("suggestion for \(path, privacy: .public): model finished without calling setSessionName (\(elapsed, format: .fixed(precision: 1))s)")
            return nil
        }
        logger.info("suggestion for \(path, privacy: .public): '\(name, privacy: .public)' via setSessionName (\(elapsed, format: .fixed(precision: 1))s)")
        return name
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
        lines.append("Name this session, or finish without setting a name if there is no meaningful signal.")
        return lines.joined(separator: "\n")
    }
}
