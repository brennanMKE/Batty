// LMStudioDashboardFormattingTests.swift

import Foundation
import Testing
@testable import BattyKit

struct LMStudioDashboardFormattingTests {
    @Test(arguments: [
        ("eosFound", "Finished"),
        ("maxPredictedTokensReached", "Hit token limit"),
        ("userStopped", "Stopped by user"),
        ("modelUnloaded", "Model unloaded"),
        ("failed", "Failed"),
        ("stopStringFound", "Stop string found"),
        ("toolCalls", "Tool calls"),
        ("contextLengthReached", "Context length reached"),
    ])
    func knownStopReasonsMapToPlainWords(raw: String, expected: String) {
        #expect(LMStudioDashboardFormatting.stopReasonDisplayName(raw) == expected)
    }

    @Test(arguments: [
        ("brandNewReason", "Brand new reason"),
        ("snake_case_reason", "Snake case reason"),
        ("single", "Single"),
        ("", ""),
    ])
    func unknownStopReasonsAreSplitIntoWords(raw: String, expected: String) {
        #expect(LMStudioDashboardFormatting.stopReasonDisplayName(raw) == expected)
    }

    @Test func tallyUsesDisplayNamesMostFrequentFirst() {
        let reasons = Array(repeating: "eosFound", count: 6) + ["maxPredictedTokensReached"]
        #expect(LMStudioDashboardFormatting.stopReasonTallyText(reasons) == "Hit token limit: 1")
        let mixed = ["failed", "failed", "maxPredictedTokensReached", "eosFound", "eosFound", "eosFound"]
        #expect(LMStudioDashboardFormatting.stopReasonTallyText(mixed) == "Failed: 2  ·  Hit token limit: 1")
    }

    @Test func tallyMergesReasonsThatShareADisplayName() {
        #expect(LMStudioDashboardFormatting.stopReasonTallyText(["toolCalls", "tool_calls", "tool-calls"]) == "Tool calls: 3")
    }

    @Test func displaySeverityPrefersLevelThenMessageTag() {
        #expect(LMStudioDashboardFormatting.displaySeverity(level: "warn", message: "[ERROR] x") == "warn")
        #expect(LMStudioDashboardFormatting.displaySeverity(level: "debug", message: "a [ERROR]: b") == "error")
        #expect(LMStudioDashboardFormatting.displaySeverity(level: "debug", message: "[WARNING]") == "warning")
    }

    @Test func tallyBreaksTiesByLabel() {
        #expect(LMStudioDashboardFormatting.stopReasonTallyText(["toolCalls", "failed"]) == "Failed: 1  ·  Tool calls: 1")
        #expect(LMStudioDashboardFormatting.stopReasonTallyText([]) == nil)
    }

    @Test func tallyIsNilWhenEveryCompletionFinished() {
        #expect(LMStudioDashboardFormatting.stopReasonTallyText(Array(repeating: "eosFound", count: 4)) == nil)
    }

    private func entry(level: String?, message: String?) -> LMStudioEngineLogEntry {
        LMStudioEngineLogEntry(id: UUID(), timestamp: Date(), level: level, message: message, engineName: "mlx")
    }

    @Test func filterKeepsOnlyWarningAndErrorEntries() {
        let entries = [
            entry(level: "debug", message: "[batched_model_kit][INFO]: BatchedModelKit loaded successfully"),
            entry(level: "info", message: "plain"),
            entry(level: "warn", message: "careful"),
            entry(level: "WARNING", message: nil),
            entry(level: "error", message: "boom"),
            entry(level: "debug", message: "[engine][error]: tagged in message"),
            entry(level: "debug", message: "x [WARN] y"),
            entry(level: nil, message: nil),
            entry(level: "debug", message: "stopGenerating() without a request_id is deprecated"),
        ]
        let kept = LMStudioDashboardFormatting.warningsAndErrors(entries)
        #expect(kept.map(\.id) == [entries[2].id, entries[3].id, entries[4].id, entries[5].id, entries[6].id])
    }

    @Test func sectionTitleCountsOnlyTheGivenEntries() {
        #expect(LMStudioDashboardFormatting.engineSectionTitle(count: 0) == "Engine Errors & Warnings (0)")
    }
}
