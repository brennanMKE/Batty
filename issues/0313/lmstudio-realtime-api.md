# LM Studio Realtime Interfaces — Reference for a Live Dashboard

Notes on every way to get realtime (or near-realtime) data out of LM Studio, for building a
visualizer of what's happening inside it. Everything below was verified live on **2026-08-07**
against the mini's LM Studio server (`ornith-1.0-35b-mlx-oq8` loaded, 65536 ctx, parallel 2)
unless explicitly marked as unverified.

**Summary:** there is exactly one push feed (the diagnostics log stream, available via CLI or SDK)
and everything else is polling. There is no general-purpose `/events` SSE endpoint.

---

## 1. `lms log stream` — the event firehose (primary data source)

```bash
lms log stream --json --stats
```

Emits **NDJSON**: one JSON object per line, plus a `Streaming logs from LM Studio` banner line and a
blank line at the top (skip non-JSON lines when parsing).

### Flags

| Flag | Effect |
|---|---|
| `--json` | NDJSON output instead of pretty-printed text. Required for programmatic use. |
| `--stats` | Include the `stats` block on prediction-output events. **Without this you get no tok/s or TTFT.** |
| `-s, --source <model\|server\|runtime>` | Which log source to subscribe to. Default is `model`. |
| `--filter <input\|output>` | For the `model` source only — restrict to prompt or completion events. |

### Envelope

```json
{ "timestamp": 1786141251739, "data": { "type": "...", ... } }
```

`timestamp` is epoch milliseconds. All event-specific fields live under `data`.

### Event types

Source of truth: `packages/lms-shared-types/src/diagnostics/DiagnosticsLogEvent.ts` in
[`lmstudio-ai/lmstudio-js`](https://github.com/lmstudio-ai/lmstudio-js) — a zod discriminated union
on `type`.

#### `llm.prediction.input` — fires when a prediction starts

```json
{
  "type": "llm.prediction.input",
  "input": "<|im_start|>system\n# Tools\n…",
  "modelPath": "…",
  "modelIdentifier": "ornith-1.0-35b-mlx-oq8"
}
```

`input` is the **fully rendered prompt after the Jinja chat template** — the literal string handed to
the model, including `<|im_start|>` markers and the entire system prompt.

#### `llm.prediction.output` — fires when a prediction ends

```json
{
  "type": "llm.prediction.output",
  "output": "Let me read around line 99…",
  "modelIdentifier": "ornith-1.0-35b-mlx-oq8",
  "stats": {
    "stopReason": "eosFound",
    "tokensPerSecond": 44.01773040210423,
    "numGpuLayers": -1,
    "timeToFirstTokenSec": 0.504,
    "totalTimeSec": 1.658,
    "promptTokensCount": 28411,
    "predictedTokensCount": 73,
    "totalTokensCount": 28484
  }
}
```

`stats` is **optional** in the schema and only present with `--stats`. This is the only place the
throughput numbers are exposed — see the OpenAI-compat caveat in §5.

#### `server.log` — HTTP server activity (`-s server`)

```json
{ "type": "server.log", "content": "…", "level": "<LogLevel>" }
```

#### `runtime.log` — inference-engine messages (`-s runtime`)

```json
{
  "type": "runtime.log",
  "level": "<LogLevel>",
  "message": "…",
  "engineName": "…",
  "engineVersion": "…",
  "engineType": "…",
  "modelIdentifier": "…",      // optional
  "instanceReference": "…",    // optional
  "pid": 12345                 // optional
}
```

### Key limitation: per-prediction, not per-token

You get a **start** event and a **finish** event. The `output` event carries the whole completion at
once, with final stats. There is **no live token-by-token feed** for traffic other clients originate.

For a dashboard this means:

- **In-flight state:** an `input` event with no matching `output` yet = a request currently running.
- **Duration:** `output.timestamp − input.timestamp`, or trust `stats.totalTimeSec`.
- **Live token ticker:** not possible from this feed. Only your own requests can stream per-token
  (see §4).

---

## 2. SDK over WebSocket — same feed, programmatic

`lms log stream` is a thin wrapper over the SDK. Use this instead of spawning a subprocess if you
want the collector in-process.

**TypeScript** (`lmstudio-js`), from `packages/lms-client/src/diagnostics/DiagnosticsNamespace.ts`:

```ts
// returns an unsubscribe function; calling it terminates the stream
const unsubscribe = client.diagnostics.unstable_streamLogs(logEvent => {
  // logEvent matches the DiagnosticsLogEvent shapes in §1
})
```

The method is marked **alpha** in-source ("Do not use this method in production yet"). The
`unstable_` prefix is an API-stability warning — the feed itself works. It is what the CLI uses.

`lmstudio-python` exposes the equivalent.

### WebSocket transport

The SDK connects over WebSocket to the same port as the HTTP API. Verified live — both return
`HTTP/1.1 101 Switching Protocols`:

- `ws://localhost:1234/system`
- `ws://localhost:1234/llm`

Other namespaces exist (`embedding`, `repository`, `diagnostics`, …). The wire protocol is
channel-based and undocumented; **use the SDK rather than hand-rolling frames.**

### `system` namespace (useful, non-streaming)

From `SystemNamespace.ts` — all request/response, no events:

`listDownloadedModels(domain?)` · `listDownloadedModelVariants(modelKey)` · `whenDisconnected()` ·
`notify()` · `getLMStudioVersion()` · `getInfo()` · `startHttpServer()` · `stopHttpServer()` ·
`requestShutdown()` · `unstable_get/setExperimentFlag()`

`whenDisconnected()` is worth wiring into the dashboard for a connection-health indicator.

---

## 3. Model / instance state — polling only

**There is no push event for model load, unload, or status change.** Confirmed absent:
`GET /api/v1/events` → 404, `GET /api/v0/events` → 404, `GET /` → 404.

Poll these instead. All are cheap; ~1 Hz is fine.

### `GET /api/v1/models` — native shape

```json
{ "models": [ {
  "type": "llm",
  "key": "ornith-1.0-35b-mlx-oq8",
  "display_name": "…",
  "publisher": "jedisct1",
  "architecture": "qwen3_5_moe",
  "quantization": { "name": "8bit", "bits_per_weight": 8 },
  "size_bytes": 16081685402,
  "params_string": "27B",
  "format": "mlx",
  "max_context_length": 262144,
  "capabilities": { "vision": true, "trained_for_tool_use": true,
                    "reasoning": { "allowed_options": ["off","on"], "default": "on" } },
  "variants": ["…"],
  "selected_variant": "…",
  "loaded_instances": [
    { "id": "ornith-1.0-35b-mlx-oq8", "config": { "context_length": 65536, "parallel": 2 } }
  ]
} ] }
```

**Loaded-vs-not is expressed by a non-empty `loaded_instances` array**, and that array is where the
per-instance runtime config (context length, parallel slots) lives. This is the best single endpoint
for "what is resident right now."

### `GET /api/v0/models` — flatter legacy shape

```json
{ "data": [ {
  "id": "ornith-1.0-35b-mlx-oq8", "object": "model", "type": "vlm",
  "publisher": "jedisct1", "arch": "qwen3_5_moe",
  "compatibility_type": "mlx", "quantization": "8bit",
  "state": "loaded",                    // or "not-loaded"
  "max_context_length": 262144,
  "loaded_context_length": 65536,
  "capabilities": ["tool_use"]
} ] }
```

Has an explicit `state` field, which is simpler to bind to than checking array emptiness. Note
`type` here reports `vlm` for models that `/api/v1` reports as `llm`.

### `lms ps` — the only source for GENERATING vs IDLE

```
IDENTIFIER                MODEL                     STATUS        SIZE        CONTEXT   PARALLEL  DEVICE  TTL
ornith-1.0-35b-mlx-oq8    ornith-1.0-35b-mlx-oq8    GENERATING    37.73 GB    65536     2         Local
```

Columns `STATUS` (`GENERATING` / `IDLE`), `DEVICE`, and `TTL` are **not exposed by either REST
endpoint**. If the dashboard wants a busy/idle light without inferring it from unmatched
`llm.prediction.input` events, shell out to `lms ps` and parse. Check whether a `--json` flag exists
on your CLI build before writing a column-position parser.

### Other REST endpoints (per docs, not individually verified)

`POST /api/v1/chat` · `POST /api/v1/models/load` · `POST /api/v1/models/unload` ·
`POST /api/v1/models/download` · `GET /api/v1/models/download/status` (download progress — poll this
for a download-progress bar).

---

## 4. Per-token streaming — only for your own requests

Standard SSE on the OpenAI-compatible endpoint:

```bash
curl -N http://localhost:1234/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"ornith-1.0-35b-mlx-oq8","messages":[…],"stream":true}'
```

This gives true token-level realtime, but **only for traffic the dashboard itself originates**. It
cannot observe OpenCode's or the mobile app's requests. Useful if you want a "send a test prompt from
the dashboard and watch it stream" panel; useless for passive monitoring.

The native `/api/v1/chat` additionally emits *model load* and *prompt processing* streaming events
that the compat layers don't — relevant if the dashboard triggers loads itself.

---

## 5. Gotchas

- **`stats` is empty on the OpenAI-compat response.** A normal `/v1/chat/completions` call returns
  `"stats": {}` alongside the usual `usage` block. Token counts come from `usage`; **tok/s and TTFT
  exist only in the log stream.** The dashboard needs §1 for any performance charting.
- **The log stream is a full transcript.** `llm.prediction.input` carries the entire rendered prompt.
  A single OpenCode turn produced a ~28 KB event (28,411 prompt tokens). Plan for volume, and treat
  the feed as sensitive — it contains every prompt anyone sends the mini.
- **Run the collector on the mini.** Predictions execute there. LM Link mirrors *models* to the
  MacBook Air, but whether the Air's local `lms log stream` sees mini-originated predictions is
  **untested** — verify before building against the Air.
- **`ai.sstools.co` is an open public endpoint.** Do not reuse that vhost unauthenticated for a feed
  that rebroadcasts prompt text. Add a separate authenticated Caddy `handle` block.
- **No load/unload events.** Load/unload transitions must be detected by diffing poll results.
- **Rotating log files** live at `~/.lmstudio/server-logs/YYYY-MM/` and can be tailed as a fallback
  or for backfilling history on dashboard startup.
- **Plugins** (`lms dev`) can hook prompt preprocessing, tool provision, and token generation — an
  option if you ever need to inject or observe *mid*-request rather than at the boundaries.

---

## 6. Suggested architecture

```
        ┌──────────────────── mini (brennan-mac-mini-m4.local) ─────────────────────┐
        │                                                                          │
        │  lms log stream --json --stats ──┐                                        │
        │                                  ├──► collector ──► merged state ──► SSE ─┼──► browser UI
        │  poll 1 Hz: /api/v1/models ──────┤     (node/py)                          │
        │             lms ps ──────────────┘                                        │
        └──────────────────────────────────────────────────────────────────────────┘
```

1. **Spawn** `lms log stream --json --stats` (or use `unstable_streamLogs` in-process). Parse NDJSON,
   skipping the banner and blank lines.
2. **Pair** `llm.prediction.input` → `llm.prediction.output` by `modelIdentifier` in arrival order to
   derive in-flight requests and durations. Note `parallel: 2` means up to two concurrent
   predictions per instance can be outstanding — the events carry no request ID, so pairing is
   heuristic when both slots are busy.
3. **Poll** `/api/v1/models` (loaded set, context config) and `lms ps` (GENERATING/IDLE, TTL, device)
   at ~1 Hz; diff to synthesize load/unload events.
4. **Rebroadcast** the merged state to the browser as SSE or WebSocket.
5. **Serve** behind Caddy on the mini with authentication.

### Panels the available data supports

| Panel | Source |
|---|---|
| Loaded models, size, quant, arch, context config | `/api/v1/models` · `/api/v0/models` |
| Busy / idle light, TTL countdown, device | `lms ps` |
| Live request list (in-flight + recent) | paired `prediction.input` / `prediction.output` |
| tok/s over time, TTFT distribution | `stats.tokensPerSecond`, `stats.timeToFirstTokenSec` |
| Context-window pressure (prompt tokens vs `loaded_context_length`) | `stats.promptTokensCount` ÷ `loaded_context_length` |
| Stop-reason breakdown (`eosFound`, length, …) | `stats.stopReason` |
| Prompt/completion inspector | `input` / `output` strings |
| Engine errors & warnings | `-s runtime` / `-s server` events |
| Download progress | `GET /api/v1/models/download/status` |
| Server connection health | SDK `system.whenDisconnected()` |

**Not supported by any interface:** live token-by-token display of other clients' traffic, GPU/memory
utilization (use `powermetrics` or `ioreg` separately), and per-request identity/attribution — events
carry no client or request ID.

---

## Reference

- Docs: <https://lmstudio.ai/docs/developer>
- SDK source: <https://github.com/lmstudio-ai/lmstudio-js>
  - `packages/lms-shared-types/src/diagnostics/DiagnosticsLogEvent.ts` — event schemas
  - `packages/lms-client/src/diagnostics/DiagnosticsNamespace.ts` — `unstable_streamLogs`
  - `packages/lms-client/src/system/SystemNamespace.ts` — system methods
- CLI: `lms log stream --help`, `lms ps`, `lms --help` (CLI commit `6041ae0` as of this writing)
