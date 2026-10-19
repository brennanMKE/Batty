// NotificationSummarizer.swift

import Foundation
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "NotificationSummarizer")

/// What a `NotificationSummarizing` run produced: the exact model inputs and
/// the unmodified reply, so the caller owns sanitizing (`NotificationSummary
/// .sanitize`) and the Bell Feed capture log can record the raw exchange.
/// `rawReply == nil` with `failure == nil` means the summarizer produced
/// nothing at all (the same as a failure the caller can't classify).
public struct NotificationSummarizationResult: Sendable, Equatable {
    public enum Failure: Sendable, Equatable {
        case modelUnavailable
        case error(String)
        case cancelled
        case timedOut
    }

    public var instructions: String?
    public var prompt: String?
    public var rawReply: String?
    public var failure: Failure?

    public init(instructions: String? = nil, prompt: String? = nil, rawReply: String? = nil, failure: Failure? = nil) {
        self.instructions = instructions
        self.prompt = prompt
        self.rawReply = rawReply
        self.failure = failure
    }
}

/// Produces a short, human-readable summary of a bell notification given its
/// OSC 9 message and optional location context. The caller sanitizes
/// `rawReply`; a reply that does not survive sanitizing (or a `failure`)
/// means "no good summary" and the feed falls back to `entry.message` /
/// "Bell". Implementations must never throw to the caller.
public protocol NotificationSummarizing: AnyObject {
    func summarize(message: String?, tabTitle: String?, sessionTitle: String?) async -> NotificationSummarizationResult
}

/// Validation for model-suggested notification summaries. A summary only
/// reaches the feed or a re-posted notification if it survives `sanitize`.
public enum NotificationSummary {
    /// Maximum character length for a summary. Longer than a session name
    /// (which is 2–4 words) but still short enough for a notification body.
    public static let maxLength = 120

    private static let controlCharacters = CharacterSet.controlCharacters

    static func trimmed(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`\u{201C}\u{201D}\u{2018}\u{2019}"))
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func sanitize(_ raw: String) -> String? {
        let text = trimmed(raw)
        guard !text.isEmpty else { return nil }
        guard text.uppercased() != "NONE" else { return nil }
        guard text.count <= maxLength else { return nil }
        guard !text.unicodeScalars.contains(where: { controlCharacters.contains($0) }) else { return nil }
        return text
    }
}

/// On-device FoundationModels-backed notification summarizer. Requires macOS
/// 26+ and an available system language model. On every other configuration
/// `summarize` reports `.modelUnavailable` and the bell feed falls back to today's behavior.
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

    public func summarize(message: String?, tabTitle: String?, sessionTitle: String?) async -> NotificationSummarizationResult {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return NotificationSummarizationResult(failure: .modelUnavailable) }
        let prompt = Self.prompt(message: message, tabTitle: tabTitle, sessionTitle: sessionTitle)
        guard case .available = SystemLanguageModel.default.availability else {
            logger.info("system language model unavailable; skipping AI notification summary")
            return NotificationSummarizationResult(instructions: Self.instructions, prompt: prompt, failure: .modelUnavailable)
        }
        let session = LanguageModelSession(instructions: Self.instructions)
        let start = Date()
        let response: String
        do {
            let result = try await session.respond(to: prompt)
            response = result.content
        } catch is CancellationError {
            return NotificationSummarizationResult(instructions: Self.instructions, prompt: prompt, failure: .cancelled)
        } catch {
            logger.error("notification summary failed: \(error.localizedDescription, privacy: .public)")
            return NotificationSummarizationResult(instructions: Self.instructions, prompt: prompt, failure: .error(error.localizedDescription))
        }
        let elapsed = Date().timeIntervalSince(start)
        logger.info("notification summary replied (\(elapsed, format: .fixed(precision: 1))s)")
        return NotificationSummarizationResult(instructions: Self.instructions, prompt: prompt, rawReply: response)
        #else
        return NotificationSummarizationResult(failure: .modelUnavailable)
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
