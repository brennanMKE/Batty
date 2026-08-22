// LMStudioLogEventParsingTests.swift

import Testing
@testable import BattyKit

/// Fixtures below are verbatim NDJSON lines captured live against the
/// installed LM Studio server (this machine's CLI commit `71bd99c`,
/// drifted from the reference's pinned `6041ae0` — see `issues/0313.md`'s
/// `## Gotchas`) and, for the two-concurrent-request shape, the exact
/// bytes reproduced in `docs/design/lmstudio-dashboard-view.md` §1.3/§1.4.
@MainActor
struct LMStudioLogLineParserTests {

    @Test func skipsTheBannerLine() {
        #expect(LMStudioLogLineParser.parse("Streaming logs from LM Studio") == nil)
    }

    @Test func skipsBlankLines() {
        #expect(LMStudioLogLineParser.parse("") == nil)
        #expect(LMStudioLogLineParser.parse("   ") == nil)
    }

    @Test func skipsUnparseableGarbage() {
        #expect(LMStudioLogLineParser.parse("not json at all") == nil)
        #expect(LMStudioLogLineParser.parse("[1, 2, 3]") == nil)
    }

    @Test func parsesAPredictionInputEvent() throws {
        let line = #"{"timestamp":1786253679295,"data":{"type":"llm.prediction.input","input":"<|im_start|>user\nReply with exactly the word: pong<|im_end|>\n","modelPath":"jedisct1/Ornith-1.0-35B-MLX-oQ8","modelIdentifier":"ornith-1.0-35b-mlx-oq8"}}"#
        let event = try #require(LMStudioLogLineParser.parse(line))
        #expect(event.timestamp == 1786253679295)
        guard case .predictionInput(let modelIdentifier, let rawText) = event.kind else {
            Issue.record("expected predictionInput")
            return
        }
        #expect(modelIdentifier == "ornith-1.0-35b-mlx-oq8")
        #expect(rawText?.contains("pong") == true)
    }

    @Test func parsesAPredictionOutputEventWithStats() throws {
        let line = #"{"timestamp":1786253679909,"data":{"type":"llm.prediction.output","output":"pong","stats":{"stopReason":"eosFound","tokensPerSecond":131.13535614428483,"numGpuLayers":-1,"timeToFirstTokenSec":0.598,"totalTimeSec":0.016,"promptTokensCount":19,"predictedTokensCount":2,"totalTokensCount":21},"modelIdentifier":"ornith-1.0-35b-mlx-oq8"}}"#
        let event = try #require(LMStudioLogLineParser.parse(line))
        guard case .predictionOutput(let modelIdentifier, let maybeStats, let rawText) = event.kind else {
            Issue.record("expected predictionOutput")
            return
        }
        #expect(modelIdentifier == "ornith-1.0-35b-mlx-oq8")
        #expect(rawText == "pong")
        let stats = try #require(maybeStats)
        #expect(stats.stopReason == "eosFound")
        #expect(stats.promptTokensCount == 19)
        #expect(stats.predictedTokensCount == 2)
        #expect(abs((stats.tokensPerSecond ?? 0) - 131.13535614428483) < 0.0001)
    }

    /// Design doc §1.3: the `stats` block is present even without `--stats`
    /// on the CLI build this dashboard was verified against live — the
    /// parser must not assume any particular shape, only decode what's
    /// there.
    @Test func parsesAPredictionOutputEventWithoutStatsBlock() throws {
        let line = #"{"timestamp":1786253714359,"data":{"type":"llm.prediction.output","output":"Hi! How can","modelIdentifier":"ornith-1.0-35b-mlx-oq8"}}"#
        let event = try #require(LMStudioLogLineParser.parse(line))
        guard case .predictionOutput(_, let stats, _) = event.kind else {
            Issue.record("expected predictionOutput")
            return
        }
        #expect(stats == nil)
    }

    @Test func parsesARuntimeLogEvent() throws {
        let line = #"{"timestamp":1786253679000,"data":{"type":"runtime.log","level":"error","message":"engine crashed","engineName":"mlx","engineVersion":"1.0","engineType":"llm"}}"#
        let event = try #require(LMStudioLogLineParser.parse(line))
        guard case .runtimeLog(let level, let message, let engineName) = event.kind else {
            Issue.record("expected runtimeLog")
            return
        }
        #expect(level == "error")
        #expect(message == "engine crashed")
        #expect(engineName == "mlx")
    }

    /// An unrecognized `type` (a future LM Studio build, or an event this
    /// dashboard doesn't consume) must degrade to `.other`, never throw or
    /// crash — the version-drift graceful-degradation requirement
    /// (`issues/0313.md`'s Gotchas).
    @Test func unrecognizedTypeDegradesToOtherRatherThanFailing() throws {
        let line = #"{"timestamp":1,"data":{"type":"some.future.event","stuff":true}}"#
        let event = try #require(LMStudioLogLineParser.parse(line))
        guard case .other(let type) = event.kind else {
            Issue.record("expected .other")
            return
        }
        #expect(type == "some.future.event")
    }

    @Test func missingModelIdentifierOnPredictionEventsFailsClosedAsNil() {
        let line = #"{"timestamp":1,"data":{"type":"llm.prediction.input","input":"x"}}"#
        #expect(LMStudioLogLineParser.parse(line) == nil)
    }
}
