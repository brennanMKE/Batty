// LMStudioLogEvent.swift

import Foundation

/// `stats` block on an `llm.prediction.output` event — the only place
/// tok/s and time-to-first-token are exposed (`issues/0313/
/// lmstudio-realtime-api.md` §5; the OpenAI-compat response's own `stats`
/// is always `{}`). Every field optional: the design doc §1.3 confirms the
/// block is present even without `--stats` on the installed CLI build, but
/// this parser must not assume any particular build's behavior — a
/// version-drifted `lms` should degrade to missing fields, not a decode
/// failure (`issues/0313.md`'s Gotchas: version-drift must degrade
/// gracefully, never crash).
public nonisolated struct LMStudioPredictionStats: Codable, Sendable, Equatable {
    public let stopReason: String?
    public let tokensPerSecond: Double?
    public let timeToFirstTokenSec: Double?
    public let totalTimeSec: Double?
    public let promptTokensCount: Int?
    public let predictedTokensCount: Int?
    public let totalTokensCount: Int?
}

/// The subset of `lms log stream --json` event types this dashboard
/// consumes. `server.log` is deliberately not modeled here — design doc
/// §1.8 found it leaks full request/completion bodies at the default
/// `info` level, so the pane never subscribes to `-s server` at all and
/// this parser has no reason to recognize its shape.
public nonisolated enum LMStudioLogEventKind: Sendable, Equatable {
    /// Fires when a prediction starts. `rawText` is the fully-rendered
    /// prompt (`data.input`) — extracted here so the Prompt Inspector
    /// opt-in (design doc §2.1/§6) can use it, but the caller is
    /// responsible for discarding it immediately unless the inspector is
    /// enabled. Parsing it does not by itself retain it anywhere.
    case predictionInput(modelIdentifier: String, rawText: String?)
    /// Fires when a prediction ends, carrying the whole completion at
    /// once — never token-by-token (`issues/0313/lmstudio-realtime-api.md`
    /// §1, confirmed live in design doc §1.3).
    case predictionOutput(modelIdentifier: String, stats: LMStudioPredictionStats?, rawText: String?)
    case runtimeLog(level: String?, message: String?, engineName: String?)
    case other(type: String)
}

public nonisolated struct LMStudioLogEvent: Sendable, Equatable {
    /// Epoch milliseconds, per the envelope (`{"timestamp": ..., "data": {...}}`).
    public let timestamp: Int64
    public let kind: LMStudioLogEventKind

    public var date: Date { Date(timeIntervalSince1970: Double(timestamp) / 1000) }
}

/// Parses one line of `lms log stream --json` output. NDJSON, one JSON
/// object per line, plus a `Streaming logs from LM Studio` banner line and
/// a blank line at the top that must be skipped
/// (`issues/0313/lmstudio-realtime-api.md` §1, re-confirmed live in
/// design doc §1.3).
///
/// Uses `JSONSerialization` rather than a `Decodable` discriminated union:
/// the envelope's `data.type` field decides which shape the rest of `data`
/// has, and a dictionary-based switch is simpler to keep tolerant of an
/// unrecognized or version-drifted `type` than fighting `Decodable`'s
/// single-shape-per-type expectation.
public nonisolated enum LMStudioLogLineParser {
    public static func parse(_ line: String) -> LMStudioLogEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else {
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let timestamp = intValue(json["timestamp"]),
              let eventData = json["data"] as? [String: Any],
              let type = eventData["type"] as? String
        else {
            return nil
        }

        switch type {
        case "llm.prediction.input":
            guard let modelIdentifier = eventData["modelIdentifier"] as? String else { return nil }
            return LMStudioLogEvent(
                timestamp: timestamp,
                kind: .predictionInput(modelIdentifier: modelIdentifier, rawText: eventData["input"] as? String)
            )
        case "llm.prediction.output":
            guard let modelIdentifier = eventData["modelIdentifier"] as? String else { return nil }
            return LMStudioLogEvent(
                timestamp: timestamp,
                kind: .predictionOutput(
                    modelIdentifier: modelIdentifier,
                    stats: decodeStats(from: eventData["stats"]),
                    rawText: eventData["output"] as? String
                )
            )
        case "runtime.log":
            return LMStudioLogEvent(
                timestamp: timestamp,
                kind: .runtimeLog(
                    level: eventData["level"] as? String,
                    message: eventData["message"] as? String,
                    engineName: eventData["engineName"] as? String
                )
            )
        default:
            return LMStudioLogEvent(timestamp: timestamp, kind: .other(type: type))
        }
    }

    private static func intValue(_ raw: Any?) -> Int64? {
        if let n = raw as? Int64 { return n }
        if let n = raw as? Int { return Int64(n) }
        if let n = raw as? Double { return Int64(n) }
        if let n = raw as? NSNumber { return n.int64Value }
        return nil
    }

    private static func decodeStats(from raw: Any?) -> LMStudioPredictionStats? {
        guard let dict = raw as? [String: Any], !dict.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: dict)
        else {
            return nil
        }
        return try? JSONDecoder().decode(LMStudioPredictionStats.self, from: data)
    }
}
