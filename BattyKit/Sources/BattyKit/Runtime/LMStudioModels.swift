// LMStudioModels.swift

import Foundation

/// `GET /api/v1/models` response shape, verified live against the
/// installed LM Studio server — `issues/0313/lmstudio-realtime-api.md` §3,
/// re-verified in `docs/design/lmstudio-dashboard-view.md` §1.6. Chosen
/// over `/api/v0/models` because it is the only endpoint carrying
/// per-instance `context_length`/`parallel` (`LMStudioInstanceConfig`),
/// which the dashboard's context-pressure figure and in-flight-slot-count
/// framing both need (design doc §1.6).
public nonisolated struct LMStudioModelsResponse: Decodable, Sendable, Equatable {
    public let models: [LMStudioModelInfo]
}

public nonisolated struct LMStudioModelInfo: Decodable, Sendable, Equatable, Identifiable {
    public var id: String { key }
    public let type: String?
    public let key: String
    public let displayName: String
    public let publisher: String?
    public let architecture: String?
    public let quantization: LMStudioQuantization?
    public let sizeBytes: Int64?
    public let paramsString: String?
    public let format: String?
    /// Loaded-vs-not is expressed by whether this is non-empty — there is
    /// no separate boolean field on this endpoint (design doc §1.6).
    public let loadedInstances: [LMStudioLoadedInstance]
    public let maxContextLength: Int?

    public var isLoaded: Bool { !loadedInstances.isEmpty }

    enum CodingKeys: String, CodingKey {
        case type, key
        case displayName = "display_name"
        case publisher, architecture, quantization
        case sizeBytes = "size_bytes"
        case paramsString = "params_string"
        case format
        case loadedInstances = "loaded_instances"
        case maxContextLength = "max_context_length"
    }
}

public nonisolated struct LMStudioLoadedInstance: Decodable, Sendable, Equatable {
    public let id: String
    public let config: LMStudioInstanceConfig
}

public nonisolated struct LMStudioInstanceConfig: Decodable, Sendable, Equatable {
    public let contextLength: Int?
    public let parallel: Int?

    enum CodingKeys: String, CodingKey {
        case contextLength = "context_length"
        case parallel
    }
}

public nonisolated struct LMStudioQuantization: Decodable, Sendable, Equatable {
    public let name: String?
    public let bitsPerWeight: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case bitsPerWeight = "bits_per_weight"
    }
}

/// `lms ps --json` output shape. Unlike `/api/v1/models`, fields here are
/// already camelCase (verified live, design doc §1.2) — no `CodingKeys`
/// translation needed. `status` is confirmed lowercase ("idle"/"generating"),
/// not the human table's uppercase — a naive parser written against the
/// table would silently never match (design doc §1.2).
public nonisolated struct LMStudioPsEntry: Decodable, Sendable, Equatable {
    public let identifier: String
    public let modelKey: String?
    public let status: String
    public let deviceIdentifier: String?
    public let ttlMs: Int?

    public var isGenerating: Bool { status.lowercased() == "generating" }
    public var isIdle: Bool { status.lowercased() == "idle" }
}
