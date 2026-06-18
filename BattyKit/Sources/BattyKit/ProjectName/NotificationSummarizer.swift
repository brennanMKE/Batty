// NotificationSummarizer.swift

import Foundation
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "NotificationSummarizer")

/// Produces a short, human-readable summary of a bell notification given its
/// OSC 9 message and optional location context. Returning `nil` means "no
/// good summary" — the caller falls back to today's `entry.message` / "Bell"
/// behavior. Implementations must never throw to the caller.
public protocol NotificationSummarizing: AnyObject {
    func summarize(message: String?, tabTitle: String?, sessionTitle: String?) async -> String?
}

/// Validation for model-suggested notification summaries. A summary only
/// reaches the feed or a re-posted notification if it survives `sanitize`.
public enum NotificationSummary {
    /// Maximum character length for a summary. Longer than a session name
    /// (which is 2–4 words) but still short enough for a notification body.
    public static let maxLength = 120

    private static let controlCharacters = CharacterSet.controlCharacters

    public static func sanitize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`\u{201C}\u{201D}\u{2018}\u{2019}"))
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.uppercased() != "NONE" else { return nil }
        guard text.count <= maxLength else { return nil }
        guard !text.unicodeScalars.contains(where: { controlCharacters.contains($0) }) else { return nil }
        return text
    }
}

/// On-device FoundationModels-backed notification summarizer. Requires macOS
/// 26+ and an available system language model. On every other configuration
/// `summarize` returns `nil` and the bell feed falls back to today's behavior.
public final class FoundationModelsNotificationSummarizer: NotificationSummarizing {
    static let instructions = """
        You summarize terminal bell notifications into a single short phrase \
        (at most one sentence, no punctuation at the end) that describes what \
        happened — for example "build failed: 3 errors", "tests passed", \
        "npm install finished", "deploy succeeded". \
        Use the OSC 9 message and any provided context to produce a concise, \
        human-readable description. \
        If you cannot determine anything meaningful, respond with just: NONE
        """

    /// Returns a live summarizer when the OS can possibly host the model,
    /// `nil` otherwise. Model availability is re-checked on every call.
    public static func makeIfAvailable() -> NotificationSummarizing? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return FoundationModelsNotificationSummarizer()
        }
        #endif
        return nil
    }

    public init() {}

    public func summarize(message: String?, tabTitle: String?, sessionTitle: String?) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return nil }
        guard case .available = SystemLanguageModel.default.availability else {
            logger.info("system language model unavailable; skipping AI notification summary")
            return nil
        }
        let prompt = Self.prompt(message: message, tabTitle: tabTitle, sessionTitle: sessionTitle)
        let session = LanguageModelSession(instructions: Self.instructions)
        let start = Date()
        let response: String
        do {
            let result = try await session.respond(to: prompt)
            response = result.content
        } catch is CancellationError {
            return nil
        } catch {
            logger.error("notification summary failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let elapsed = Date().timeIntervalSince(start)
        guard let summary = NotificationSummary.sanitize(response), summary.uppercased() != "NONE" else {
            logger.info("notification summary: model returned no summary (\(elapsed, format: .fixed(precision: 1))s)")
            return nil
        }
        logger.info("notification summary: '\(summary, privacy: .public)' (\(elapsed, format: .fixed(precision: 1))s)")
        return summary
        #else
        return nil
        #endif
    }

    static func prompt(message: String?, tabTitle: String?, sessionTitle: String?) -> String {
        var parts: [String] = []
        if let message, !message.isEmpty {
            parts.append("Message: \(message)")
        }
        if let tabTitle, !tabTitle.isEmpty {
            parts.append("Tab: \(tabTitle)")
        }
        if let sessionTitle, !sessionTitle.isEmpty {
            parts.append("Session: \(sessionTitle)")
        }
        if parts.isEmpty {
            parts.append("(no message or context)")
        }
        parts.append("Summarize this notification in a short phrase.")
        return parts.joined(separator: "\n")
    }
}
