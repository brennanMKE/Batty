// LMStudioModelsDecodingTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Fixtures captured live against `http://localhost:1234` on this
/// machine (`GET /api/v1/models`, `lms ps --json`) while implementing
/// #0313 phase 2 — the installed CLI reports commit `71bd99c`, drifted
/// from the reference's pinned `6041ae0` (`issues/0313.md`'s `##
/// Gotchas`), so these fixtures also double as this implementation's own
/// re-verification of the wire shape against a live, if drifted, build.
@MainActor
struct LMStudioModelsDecodingTests {

    @Test func decodesAModelsResponseWithLoadedAndUnloadedEntries() throws {
        let json = """
        {
          "models": [
            {
              "type": "llm",
              "publisher": "ornith-ai",
              "key": "ornith-1.5-9b-mlx",
              "display_name": "Ornith 1.5 9B",
              "architecture": "qwen3_5",
              "quantization": { "name": "4bit", "bits_per_weight": 4 },
              "size_bytes": 5059937830,
              "params_string": "9B",
              "loaded_instances": [],
              "max_context_length": 262144,
              "format": "mlx"
            },
            {
              "type": "llm",
              "publisher": "ornith-ai",
              "key": "ornith-1.5-35b-a3b-mlx",
              "display_name": "Ornith 1.5 35B A3B",
              "architecture": "qwen3_5_moe",
              "quantization": { "name": "4bit", "bits_per_weight": 4 },
              "size_bytes": 19530912282,
              "params_string": "35B",
              "loaded_instances": [
                { "id": "ornith-1.5-35b-a3b-mlx", "config": { "context_length": 65536, "parallel": 4, "reasoning_budget_message": "" } }
              ],
              "max_context_length": 262144,
              "format": "mlx"
            }
          ]
        }
        """
        let response = try JSONDecoder().decode(LMStudioModelsResponse.self, from: Data(json.utf8))
        #expect(response.models.count == 2)
        let unloaded = try #require(response.models.first { $0.key == "ornith-1.5-9b-mlx" })
        #expect(unloaded.isLoaded == false)
        let loaded = try #require(response.models.first { $0.key == "ornith-1.5-35b-a3b-mlx" })
        #expect(loaded.isLoaded == true)
        #expect(loaded.loadedInstances.first?.config.contextLength == 65536)
        #expect(loaded.loadedInstances.first?.config.parallel == 4)
        #expect(loaded.quantization?.name == "4bit")
        #expect(loaded.sizeBytes == 19530912282)
    }

    /// An extra, unmodeled key inside `loaded_instances[].config` (this
    /// build emits `reasoning_budget_message`, absent from the reference)
    /// must not fail decoding — version drift should be tolerated, not
    /// crash (`issues/0313.md`'s Gotchas).
    @Test func toleratesAnUnmodeledConfigKeyFromVersionDrift() throws {
        let json = """
        { "models": [ { "type":"llm","key":"m","display_name":"M","loaded_instances":[
            { "id":"m", "config": { "context_length": 4096, "parallel": 1, "brand_new_field": 42 } }
          ] } ] }
        """
        let response = try JSONDecoder().decode(LMStudioModelsResponse.self, from: Data(json.utf8))
        #expect(response.models.first?.loadedInstances.first?.config.contextLength == 4096)
    }

    @Test func decodesPsEntriesWithLowercaseStatus() throws {
        let json = """
        [{"type":"llm","modelKey":"ornith-1.5-35b-a3b-mlx","format":"safetensors",
          "displayName":"Ornith 1.5 35B A3B","publisher":"ornith-ai",
          "path":"ornith-ai/Ornith-1.5-35B-A3B-MLX-4bit","sizeBytes":19530912282,
          "deviceIdentifier":null,"paramsString":"35B","architecture":"qwen3_5_moe",
          "quantization":{"name":"4bit","bits":4},"identifier":"ornith-1.5-35b-a3b-mlx",
          "ttlMs":null,"vision":false,"trainedForToolUse":true,"maxContextLength":262144,
          "contextLength":65536,"status":"idle","queued":0,"parallel":4}]
        """
        let entries = try JSONDecoder().decode([LMStudioPsEntry].self, from: Data(json.utf8))
        let entry = try #require(entries.first)
        #expect(entry.identifier == "ornith-1.5-35b-a3b-mlx")
        #expect(entry.status == "idle")
        #expect(entry.isIdle)
        #expect(entry.isGenerating == false)
        #expect(entry.deviceIdentifier == nil)
        #expect(entry.ttlMs == nil)
    }

    @Test func generatingStatusIsRecognizedCaseInsensitively() throws {
        let json = #"[{"identifier":"m","status":"generating"}]"#
        let entries = try JSONDecoder().decode([LMStudioPsEntry].self, from: Data(json.utf8))
        #expect(entries.first?.isGenerating == true)
    }
}
