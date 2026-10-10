// LMStudioDashboardFormatting.swift

import Foundation

/// Pure presentation helpers for `LMStudioDashboardView`, kept out of `body`
/// so they are unit-testable without a connected LM Studio server.
nonisolated enum LMStudioDashboardFormatting {
    /// Known `LLMPredictionStopReason` values from the LM Studio SDK's
    /// `llmPredictionStopReasonSchema`.
    private static let knownStopReasons: [String: String] = [
        "userStopped": "Stopped by user",
        "modelUnloaded": "Model unloaded",
        "failed": "Failed",
        "eosFound": "Finished",
        "stopStringFound": "Stop string found",
        "toolCalls": "Tool calls",
        "maxPredictedTokensReached": "Hit token limit",
        "contextLengthReached": "Context length reached",
    ]

    static func stopReasonDisplayName(_ raw: String) -> String {
        if let known = knownStopReasons[raw] { return known }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }
        var words: [String] = []
        var current = ""
        for character in trimmed {
            if character == "_" || character == "-" || character == " " {
                if !current.isEmpty { words.append(current); current = "" }
            } else if character.isUppercase, let last = current.last, !last.isUppercase {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        let sentence = words.map { $0.lowercased() }.joined(separator: " ")
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }

    /// "Finished: 6  ·  Hit token limit: 1", most frequent first, ties by label.
    static func stopReasonTallyText(_ reasons: [String]) -> String? {
        var tally: [String: Int] = [:]
        for reason in reasons {
            tally[stopReasonDisplayName(reason), default: 0] += 1
        }
        guard !tally.isEmpty else { return nil }
        return tally
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "  ·  ")
    }

    private static let severeLevels: Set<String> = ["warn", "warning", "error"]
    private static let severeTags = ["[warn]", "[warning]", "[error]"]

    static func isWarningOrError(level: String?, message: String?) -> Bool {
        if let level, severeLevels.contains(level.lowercased()) { return true }
        if let message {
            let lowered = message.lowercased()
            return severeTags.contains { lowered.contains($0) }
        }
        return false
    }

    /// The severity to show for a qualifying entry: its own level when that
    /// is warn/warning/error, otherwise the level named by a message tag.
    static func displaySeverity(level: String?, message: String?) -> String {
        if let level, severeLevels.contains(level.lowercased()) { return level.lowercased() }
        let lowered = message?.lowercased() ?? ""
        if lowered.contains("[error]") { return "error" }
        if lowered.contains("[warning]") { return "warning" }
        if lowered.contains("[warn]") { return "warn" }
        return level ?? "?"
    }

    static func warningsAndErrors(_ entries: [LMStudioEngineLogEntry]) -> [LMStudioEngineLogEntry] {
        entries.filter { isWarningOrError(level: $0.level, message: $0.message) }
    }

    static func engineSectionTitle(count: Int) -> String {
        "Engine Errors & Warnings (\(count))"
    }
}
