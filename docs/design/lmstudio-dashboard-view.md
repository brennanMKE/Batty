# LM Studio dashboard view — design (phase 1 of `#0313`)

Design proposal for `#0313`'s design-gated phase 1: the fourth concrete
non-terminal Pane content kind, `lm-studio-dashboard` — live observability
into a local LM Studio server (which models are loaded, whether inference
is running, recent prediction activity). **No code ships with this
document** except the throwaway verification spike described in §1, which
ran against a live LM Studio server and is not part of this commit. Read
`docs/pane-kinds.md` (where kind lives, how `PaneView` branches, the
terminal-host boundary) and `docs/pane-view-lifecycle.md` (the
`PaneContentLifecycle` contract this view is a client of) first — this
document assumes both and does not re-explain them. Also read
`docs/design/git-status-view.md`, `docs/design/process-status-view.md`, and
`docs/design/system-metrics-view.md` (the three sibling designs already
landed) — this is the fourth view in the same family, follows the same
visual language, and this document calls out where it deliberately departs
from that precedent rather than re-deriving decisions already settled
there.

The issue's own attachment, `issues/0313/lmstudio-realtime-api.md` (the
"reference"), was written and verified against the user's Mac mini on
2026-08-07. Per the issue's explicit instruction, this document does not
treat the reference as ground truth — §1 re-verifies its claims live,
following the pattern of `docs/design/process-status-view.md` §1 and
`docs/design/system-metrics-view.md` §1, both of which found and corrected
real errors in their own first-draft spikes. Every citation in this
document that is *this* document's own finding is a `file:line` or a
command transcript reproduced below; every citation carried from the
reference without independent re-verification is marked "from the
reference, not re-verified."

---

## 0. What's already decided upstream, and what this document adds

`#0302`/`#0303` settled the *shape* a non-terminal kind must fit into;
`#0304`/`#0305`/`#0314` phase 1 set the visual and documentation precedent
this view follows. This document is the fourth thing to fill that shape
in:

- **Kind identifier.** Following `docs/pane-kinds.md` §5's "one string,
  three call sites" rule (used by `#0304` for `git-status`, `#0305` for
  `process-status`, `#0314` for `system-metrics`), this document names the
  kind `lm-studio-dashboard` — the `PaneContentKind` raw value, the CLI
  `--view` flag value, and the `TopologyPanePayload.kind` JSON value are
  all literally `"lm-studio-dashboard"`. `docs/pane-kinds.md` §5 itself
  anticipated this exact spelling in Swift form
  (`.lmStudioDashboard`) when naming plausible `isSingletonPerSession`
  cases — confirmed below, §0's last bullet.
- **The pane has no Tab bar and no `TabRuntime`s** (`docs/pane-kinds.md`
  §1) — everything below describes the single view that fills an
  `lm-studio-dashboard` pane's body.
- **The conformer is model-owned**, hung off `PaneRuntime` the same way
  `docs/pane-view-lifecycle.md` §5 requires for every non-terminal kind.
  This document names the concrete conformer, `LMStudioDashboardPaneContent`,
  and what it holds.
- **Not built here**: the `PaneContentKind` enum case, `PaneRuntime.kind`,
  `PaneView`'s kind-switch, the CLI verb (`#0315`). This document is
  scoped to the view's own design — its data source, its refresh strategy,
  its visual content, its privacy posture — so `#0313`'s phase 2 and
  `#0315` each have a settled thing to wire in.
- **Singleton-per-scope: yes, following `#0314`'s reasoning exactly.**
  `docs/pane-kinds.md` §5 names `#0313`'s hypothetical kind as "a plausible
  `true` case" for `PaneContentKind.isSingletonPerSession`. This document
  confirms it for the same structural reason `#0314` confirmed it for
  `system-metrics`: two `lm-studio-dashboard` panes would show the
  *identical* server's state twice — there is no per-pane targeting
  parameter the way `process-status`'s pid or `git-status`'s path gives
  each pane a distinct subject. (This holds even under §2.2's
  remote-capable option below, in the unlikely event a future revision
  lets a pane target *which* server — that would be a targeting parameter
  making it non-singleton *per target*, not evidence against
  singleton-per-identical-subject today, since phase 1 targets exactly one
  server.) `isSingletonPerSession = true`; enforcing it is `#0315`'s, per
  `docs/pane-kinds.md` §5.

---

## 1. Verifying the reference against the live server

Every command below was run directly against `http://localhost:1234` and
the installed `lms` CLI on **2026-08-08/09, on `brennan-mac-mini-m4.local`**
(confirmed via `hostname`, `sw_vers`: macOS 26.5.1, build 25F80, arm64,
`Mac16,11`) — the *same physical Mac mini* the reference names as its own
verification machine. This matters for §2.2 below: this spike ran
same-machine-as-server, so it says nothing new about whether a *different*
Mac (a MacBook Air) can see the mini's predictions — that remains
untested, exactly as the reference already states.

`lms --help`'s banner reports **CLI commit `6041ae0`**, matching the
reference's own pinned commit exactly — this spike verifies the identical
CLI build the reference was written against, not a drifted one.

### 1.1 The 404 claims — partially wrong, corrected

The reference states "`GET /api/v1/events`, `/api/v0/events`, and `/` all
return 404." Reproduced directly:

```
$ curl -s -o /dev/null -w "http %{http_code}\n" http://localhost:1234/api/v1/events
http 404
$ curl -s -o /dev/null -w "http %{http_code}\n" http://localhost:1234/api/v0/events
http 200
$ curl -s -o /dev/null -w "http %{http_code}\n" http://localhost:1234/
http 200
```

Only `/api/v1/events` is a literal HTTP 404. `/api/v0/events` and `/` both
return **HTTP 200** with a JSON error body:

```
$ curl -sI http://localhost:1234/api/v0/events   # (and same for /)
HTTP/1.1 200 OK
X-Powered-By: Express
Content-Type: application/json; charset=utf-8
...
$ curl -s http://localhost:1234/api/v0/events
{"error":"Unexpected endpoint or method. (GET /api/v0/events)"}
```

**The reference's operative conclusion still holds — none of these three
routes is a working SSE/events endpoint, so "there is no general-purpose
push feed beyond the log stream" is correct.** But the specific claim "all
return 404" is wrong for two of the three routes on this exact CLI build,
and a design or client that branch on HTTP status code (e.g. "404 means
route absent, non-404 means something's there") would misread `/api/v0/events`
and `/` as present. **Design consequence:** any code that probes these
routes to *confirm* no events endpoint exists must check the JSON error
body's shape (`{"error":"Unexpected endpoint or method..."}`), not just the
status code — this design doesn't need to probe them at runtime at all
(the conclusion is fixed, not discovered per-launch), but the wrong-status
finding is worth recording precisely since it's exactly the kind of
confidently-wrong-code claim `#0314`'s own review rounds caught twice in
sibling documents.

### 1.2 `lms` CLI and `--json` flags — confirmed present and working

`which lms` → `/Users/brennan/.lmstudio/bin/lms`. `lms ps --json` and
`lms log stream --json --stats` both work as documented:

```
$ lms ps --json
[{"type":"llm","modelKey":"ornith-1.0-35b-mlx-oq8","format":"safetensors",
"displayName":"Ornith 1.0 35B OQ8","publisher":"jedisct1",
"path":"jedisct1/Ornith-1.0-35B-MLX-oQ8","sizeBytes":37726897291,
"indexedModelIdentifier":"jedisct1/Ornith-1.0-35B-MLX-oQ8",
"deviceIdentifier":null,"paramsString":"35B","architecture":"qwen3_5_moe",
"quantization":{"name":"8bit","bits":8},"identifier":"ornith-1.0-35b-mlx-oq8",
"ttlMs":null,"lastUsedTime":1786252670392,"vision":true,
"trainedForToolUse":true,"maxContextLength":262144,"contextLength":65536,
"status":"idle","queued":0,"parallel":2}]
```

The reference only warns to *check for* a `--json` flag before writing a
column-position parser; it doesn't report what the JSON actually looks
like once found. Two things worth designing against, neither in the
reference:

- **`status` is lowercase JSON (`"idle"`/`"generating"`), not the
  uppercase `IDLE`/`GENERATING` shown in the human-readable table** — a
  parser written against the table's casing would silently never match.
- **There is no `"device": "Local"` field in the JSON** the way the table
  column implies — the JSON key is `deviceIdentifier`, and it reads `null`
  for this on-device model. The human table's `DEVICE` column showing
  `Local` is derived display text, not a literal field value; a design
  binding directly to `deviceIdentifier` needs a `null → "Local"` mapping
  it must own itself, not read off the wire.

### 1.3 Log stream shape — confirmed, with one real correction

Captured a real prediction end to end:

```bash
lms log stream --json --stats > out.ndjson &
curl -s http://localhost:1234/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"ornith-1.0-35b-mlx-oq8","messages":[{"role":"user","content":"Reply with exactly the word: pong"}],"max_tokens":10,"stream":false}'
```

```json
{"timestamp":1786253679295,"data":{"type":"llm.prediction.input","input":"<|im_start|>user\nReply with exactly the word: pong<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n","modelPath":"jedisct1/Ornith-1.0-35B-MLX-oQ8","modelIdentifier":"ornith-1.0-35b-mlx-oq8"}}
{"timestamp":1786253679909,"data":{"type":"llm.prediction.output","output":"pong","stats":{"stopReason":"eosFound","tokensPerSecond":131.13535614428483,"numGpuLayers":-1,"timeToFirstTokenSec":0.598,"totalTimeSec":0.016,"promptTokensCount":19,"predictedTokensCount":2,"totalTokensCount":21},"modelIdentifier":"ornith-1.0-35b-mlx-oq8"}}
```

**Confirmed exactly as the reference describes:** the envelope shape, both
event types' field names, no request-id field anywhere on either event,
`output` carrying the whole completion string at once ("pong", observed
whole in one event, never streamed token-by-token). The
`Streaming logs from LM Studio` banner line (plus a blank line) at stream
start is real — confirmed on a separate run capturing just the banner —
so a parser must skip non-JSON lines, as the reference says.

**The OpenAI-compat response's `stats` block is empty, confirmed:**

```json
{"...":"...", "usage":{"prompt_tokens":19,"completion_tokens":2,"total_tokens":21,...}, "stats":{}, "system_fingerprint":"..."}
```

**One real correction:** the reference states `--stats` is "mandatory for
throughput data... without this you get no tok/s or TTFT." Tested directly
— ran `lms log stream --json` (no `--stats`) around two separate
predictions:

```json
{"timestamp":1786253714359,"data":{"type":"llm.prediction.output","output":"Hi! How can","stats":{"stopReason":"maxPredictedTokensReached","tokensPerSecond":80,"numGpuLayers":-1,"timeToFirstTokenSec":0.599,"totalTimeSec":0.05,"promptTokensCount":14,"predictedTokensCount":4,"totalTokensCount":18},"modelIdentifier":"ornith-1.0-35b-mlx-oq8"}}
```

**The `stats` block is present, fully populated, on this exact CLI build
(`6041ae0`) even without `--stats` on the command line.** Reproduced twice
independently (different prompts, both times). This does not change the
design's recommendation — `--stats` is the documented, stable way to
*request* the block (`lms log stream --help`: `--stats  Print prediction
stats if available`), and passing it defensively costs nothing and
protects against whatever CLI-version-specific behavior made this field
conditional in the reference's own testing on 2026-08-07 — but the
absolute claim "without `--stats` you get no tok/s" is empirically false
on the installed build as of this spike, and the design must not assume a
missing `--stats` flag is what explains an absent `stats` block if that's
ever observed later (something else would be going on).

### 1.4 In-flight pairing heuristic — reproduced concretely, and shown to actually mispair, not just theoretically risk it

Fired two concurrent, content-distinguishable chat completions ("count 1
to 50 by odd numbers only" vs. "count 1 to 50, one number per line")
against the same `parallel: 2` model, so the two `output` events could be
matched back to their originating `input` by content, not just by
position:

```
"timestamp":1786253764164,"data":{"type":"llm.prediction.input","input":"...odd numbers only...", ...}
"timestamp":1786253764164,"data":{"type":"llm.prediction.input","input":"...one number per line...", ...}
"timestamp":1786253767816,"data":{"type":"llm.prediction.output","output":"Here are the odd numbers from 1 to 50: ...", ...}
"timestamp":1786253768434,"data":{"type":"llm.prediction.output","output":"1\n2\n3\n4\n5\n... 50", ...}
```

**Both `input` events landed at the identical millisecond timestamp**, both
carrying the same `modelIdentifier`, neither carrying anything that
distinguishes which of the two curl processes produced it — confirming
there is no signal available to a consumer of this feed that could
disambiguate the two requests at the moment they start. **In this
particular run, the two `output` events happened to arrive in the same
order as their corresponding `input`s** (the odd-numbers request's own
output landed first, matching its input's own position) — content
correlation makes this checkable, not assumed.

**Review round 1 independently re-ran the identical experiment and
observed the two `output` events return in the opposite order from their
`input`s** — a live mispairing, not a second instance of mere
simultaneity. Taken together, the two runs make a stronger point than
either alone: **arrival-order pairing isn't consistently wrong, which
would at least be a predictable bias a UI could compensate for — it is
observably inconsistent, run to run, on the same server and the same
model.** A design that paired by arrival order would have been silently
correct in this document's own run and silently wrong in the reviewer's,
with no signal on either occasion to tell a consumer which case it was
in. §4 below states what this means in the UI's own terms, not just in
this prose.

### 1.5 Prompt volume — confirmed at a different scale than the reference's own number

Sent an 18,000-character synthetic prompt (repeated filler text):

```
prompt bytes sent: 18131
resulting llm.prediction.input event: 18257 bytes total, 18084 bytes in the "input" field
promptTokensCount reported: 4017
```

**Confirms the reference's core claim — prompt volume is real, material,
and scales with conversation size, tens of KB is not a hypothetical.**
The reference's own specific figure ("~28 KB event at 28,411 prompt
tokens") is **carried forward unverified at that magnitude** — this
spike's own ratio (~4.5 bytes of JSON per prompt token, repetitive filler
text) doesn't match the reference's implied ratio (~1 byte per prompt
token) closely enough to treat the two as cross-confirming, likely because
token density depends heavily on content (code vs. prose vs. repeated
filler) and the reference's number came from a real OpenCode turn's actual
content, not a synthetic string. Both numbers agree on the conclusion that
matters for retention design (§6): **single-digit-to-double-digit
kilobytes per event, easily reaching tens of KB, is the right order of
magnitude to design against** — the exact byte-per-token ratio isn't
load-bearing for anything this document decides.

### 1.6 `/api/v1/models` vs `/api/v0/models` — confirmed, including the `vlm`/`llm` divergence

Both endpoints polled live. `/api/v1/models` returns the loaded model with
a non-empty `loaded_instances` array carrying per-instance config exactly
as documented:

```json
{"type":"llm","key":"ornith-1.0-35b-mlx-oq8", ...,
 "loaded_instances":[{"id":"ornith-1.0-35b-mlx-oq8","config":{"context_length":65536,"parallel":2}}]}
```

`/api/v0/models`, same model, confirms the flatter shape and the explicit
`state` field:

```json
{"id":"ornith-1.0-35b-mlx-oq8","object":"model","type":"vlm", ...,
 "state":"loaded","max_context_length":262144,"loaded_context_length":65536, ...}
```

**The `vlm`-vs-`llm` `type` divergence the reference notes is confirmed
exactly**: the same model reports `"type":"llm"` on `/api/v1/models` and
`"type":"vlm"` on `/api/v0/models`. Both endpoints correctly list unloaded
models with empty `loaded_instances` (v1) / `"state":"not-loaded"` (v0).
**Design consequence, settled here for §5:** poll `/api/v1/models` as the
primary source — it's the one place per-instance `context_length` and
`parallel` live, both needed for §3's context-pressure figure and §4's
in-flight-slot-count framing; `/api/v0/models`'s only advantage (an
explicit `state` string vs. an empty-array check) isn't worth polling a
second endpoint for the same data.

### 1.7 `lms ps` — confirmed as the only GENERATING/IDLE/DEVICE/TTL source, and measurably not free

Ran `lms ps --json` in a tight poll loop around a longer generation
(300-token continuation, several seconds) to catch the transition:

```
distinct status values observed: 24× "generating", 14× "idle"
```

Confirms `lms ps --json` is the only source for busy/idle — neither REST
endpoint carries it, matching the reference. **New finding the reference
doesn't report: `lms ps --json`'s own invocation cost.** Timed ten
successive calls:

```
lms ps --json: [258.9, 142.6, 145.1, 140.7, 137.8, 140.0, 138.1, 147.4, 169.9, 154.5] ms
average 157.5 ms/call
```

versus `/api/v1/models` over HTTP:

```
curl /api/v1/models: [11.9, 11.4, 11.1, 11.1, 11.4, 11.1, 11.4, 11.9, 11.5, 11.6] ms
average 11.4 ms/call
```

**`lms ps --json` costs roughly 14× what the HTTP models poll costs — in
the same cost class as `#0305`'s own measured `ps`/`top` shell-outs (65 ms
/ 400 ms), not the near-free libproc calls that document otherwise
leans on.** This is a genuine, measured cost constraint the reference
doesn't surface (it only warns about *parsing*, not *invocation cost*),
and it directly shapes §5's polling cadence: `lms ps` cannot be polled at
the same cheap 1 Hz the sibling views established as a free default — at
1 Hz it would burn ~16% of a CPU core in Node-process-spawn overhead alone,
indefinitely, for as long as the pane is open. §5 designs around this by
making `lms ps` a slower, secondary-enrichment poll rather than the
primary busy/idle signal.

### 1.8 New finding: one log source per `lms log stream` invocation, and `-s server` is its own privacy surface

Not stated as a consequence anywhere in the reference, though the flag
table implies it: `-s, --source <source>` takes exactly **one** value
(`model`, `server`, or `runtime`) per invocation — there is no way to
subscribe to more than one source from a single `lms log stream` process.
Confirmed by running two subprocesses concurrently, different sources,
around the same prediction:

```bash
lms log stream --json -s model --stats  > stream_model.ndjson &
lms log stream --json -s server         > stream_server.ndjson &
```

Both ran independently and correctly — `stream_model.ndjson` got the
`llm.prediction.input`/`.output` pair; `stream_server.ndjson` got a
sequence of `server.log` events for the same request. **Design
consequence:** getting both prediction events (§3/§4's primary feed) and
server/runtime diagnostics (the reference's own "Engine errors and
warnings" panel, sourced from `-s runtime`/`-s server`) requires spawning
**multiple concurrent `lms log stream` subprocesses**, one per source of
interest — not one subprocess with a combined subscription. §5 designs
this explicitly rather than assuming a single stream covers everything.

**A second, more important finding from the same capture: `-s server`
is its own, separate privacy leak, not just a diagnostics source.** Two
lines from the captured `server.log` stream, verbatim:

```json
{"type":"server.log","level":"debug","content":"[2026-08-08 22:40:13][DEBUG] Received request: POST to /v1/chat/completions with body {\n  \"model\": \"ornith-1.0-35b-mlx-oq8\",\n  \"messages\": [\n    {\n      \"role\": \"user\",\n      \"content\": \"hi\"\n    }\n  ],\n  \"max_tokens\": 5,\n  \"stream\": false\n}"}
{"type":"server.log","level":"info","content":"[2026-08-08 22:40:16][INFO][ornith-1.0-35b-mlx-oq8] Generated prediction: {\n  \"id\": \"chatcmpl-cpghzv4d0s63fjyez9hipx\",\n  ..., \"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"Hello! How can\", ...}}], ...}"}
```

The first line (full request body, including the user's message content)
is `level: "debug"` — a naive "only show info+ level" filter would hide
it. **The second line is `level: "info"` — the default, always-visible
level — and it embeds the entire generated completion**, including
message content, inside a free-text log line. **This means the issue's own
framing — "Engine errors and warnings" sourced from `-s runtime` / `-s
server` — is not privacy-neutral the way it reads.** `-s server` carries
the same class of sensitive content `-s model` does, just serialized
differently (inside a human-readable log string rather than a structured
JSON field), and at a log level (`info`) a reasonable default filter would
not catch. **Design consequence, load-bearing for §2.1 and §3's Engine
Errors panel:** this document sources the Engine Errors & Warnings panel
from `-s runtime` **only**, by default — not `-s server` — specifically
because of this observed leak, a narrower default than the reference's own
panel-source table suggests. Re-including `-s server` would need the same
opt-in gate §2.1 designs for the prompt inspector, not a lighter one,
because it demonstrably carries the same content class.

**What this spike did not check**, named rather than assumed clean:
whether `-s runtime` output (engine-level messages — model load progress,
backend errors) ever embeds request/response content the same way
`-s server` does. No runtime-log-triggering event (a load/unload, an
engine crash) was induced in this spike to check. Phase 2 should verify
`-s runtime`'s content field the same way this section verified `-s
server`'s before trusting it as privacy-safe-by-default; until then, this
document treats the possibility as open, not resolved by assumption in
either direction, and recommends any `content`/`message` field from any
log source be treated as untrusted for verbatim rendering rather than
assumed safe because it isn't named `input`/`output`.

**A buried detail found in the same capture, noted but not built on:**
"Generated prediction"'s embedded JSON carries a real per-request id
(`"id": "chatcmpl-cpghzv4d0s63fjyez9hipx"`, the OpenAI-compat completion
id) — a correlator the `model`-source events never carry (§1.4). It does
not rescue the in-flight-pairing heuristic: extracting it would mean
parsing embedded, not-contractually-stable JSON out of a free-text log
line from the same source this document just excluded for privacy
reasons, so using it would mean re-accepting the `-s server` privacy risk
to fix a UX heuristic — not a trade this document makes. Named for
completeness, not adopted.

### 1.9 What this spike could not verify

- **`unstable_streamLogs` (the SDK/WebSocket transport) itself** — not
  independently re-tested; verifying it requires the `lmstudio-js`
  TypeScript SDK, out of scope for an HTTP/CLI spike. The alpha warning
  ("Do not use this method in production yet," `unstable_` prefix) is
  **carried from the reference, not re-verified** — but it doesn't need to
  be, since §5 recommends the CLI-subprocess transport specifically to
  avoid depending on it, matching what the reference itself names as the
  alternative.
- **Whether a MacBook Air's local `lms log stream` sees mini-originated
  predictions.** This spike ran *on* the mini (§1's header), so it cannot
  answer this — it remains exactly as untested as the reference already
  says. See §2.2.
- **The rotating log files at `~/.lmstudio/server-logs/YYYY-MM/`** — not
  inspected in this spike. The reference names them as a possible backfill
  source; this document doesn't design against them (§6 explains why).
- **The exact reference figure of 28,411 prompt tokens / ~28 KB** — see
  §1.5; the order of magnitude is confirmed, the exact ratio is not.

---

## 2. Two questions the issue says need the user's answer

Per the issue's explicit instruction, neither is decided here — each is
presented as a recommendation with its trade-off, for the user to confirm
before phase 2.

### 2.1 The prompt/completion feed — show it at all, and how

**What's at stake, confirmed by §1.3/§1.5/§1.8, not just asserted by the
issue:** `llm.prediction.input` carries the entire rendered prompt — every
system prompt, tool definition, and conversation turn any client (OpenCode
included) sends that server — and §1.8 found the *same* content class also
leaks through `-s server`'s `Generated prediction` log line at the default
visible log level. This is not a narrow, easily-scoped feature; it's two
independent places the same sensitive text can reach a Batty pane.

**Option A — Recommended: prompt/completion text is never stored or
rendered by default. The dashboard's default feed is metadata-only**
(timestamps, model identifier, duration, token counts, tok/s, TTFT, stop
reason — everything in the `stats` block, §1.3) **— no `input`/`output`
string, from either source, ever reaches memory beyond the single event
being parsed.** A separate, explicitly-opt-in "Prompt Inspector" mode
(§3's mockup state 5) can be turned on per-pane, off by default, clearly
labeled as showing raw prompt/completion text, with its own tighter
retention (§6). Turning it on is a deliberate, visible action, not a
setting buried in a preferences pane — the same "explicit, not implicit"
posture `docs/design/git-status-view.md` §1 uses for its own
"Change Directory…" retarget action, applied here to a privacy-relevant
toggle instead of a data-source toggle.

*Trade-off:* the dashboard is less immediately useful for "what exactly
did OpenCode send" debugging without deliberately opting in per pane,
every time. This is judged the right cost given §1.8's finding that a
"just don't show input/output" design is easy to get subtly wrong (the
server-log leak) if the inspector toggle isn't the *only* path to raw
text.

**Option B — Prompt/completion text shown by default, redacted or
truncated.** E.g., show the first N characters of `input`/`output`, or
redact anything that looks like a system-prompt preamble. Rejected as a
recommendation: truncation doesn't actually protect anything a full tool
definition or the start of a conversation's system prompt would still
expose in the first N characters, and "looks like a system prompt" pattern
matching is exactly the kind of heuristic privacy control that's easy to
convince yourself works and hard to verify actually does. The issue's own
framing agrees text visibility "needs the user's answer," not a plausible
partial-visibility compromise invented here.

**Option C — Prompt/completion text never available at all, not even as
an opt-in.** Simpler, but throws away real debugging value the user's own
motivating quote implies they want ("dispatching work to OpenCode... it
will be helpful to have a live view into what is happening") — "what is
happening" plausibly includes "what did it actually send," not just
throughput numbers. Rejected as more conservative than the issue's own
framing asks for; Option A already defaults to the same safety Option C
gives while keeping the door open.

**Recommendation: Option A.** Stated plainly for the user to confirm or
override: default off, explicit opt-in, tighter retention on the opt-in
path (§6), sourced only from `-s model` (never `-s server`, per §1.8) even
when the inspector is on.

### 2.2 Local-only vs remote-capable

**What's confirmed, what's still open, restated precisely rather than
loosely:** §1 confirms this spike ran directly on the mini — the same
machine the reference itself was verified against — so this document adds
**no new evidence** on whether a MacBook Air's own `lms log stream` and
HTTP polls would see mini-originated predictions. That remains exactly as
untested as the reference states. Separately, and independently of that
untested question: `ai.sstools.co` is (per the reference, not re-verified
by this spike — verifying it would mean probing a real external endpoint
outside this issue's scope) an open public endpoint that must not be
reused unauthenticated for a feed rebroadcasting prompt text, and no
authenticated remote path exists today.

**Option A — Recommended for phase 1: local-only.** The pane observes
whatever LM Studio server is reachable at `localhost:1234` on the same
Mac Batty is running on. If Batty runs on the MacBook Air while inference
happens on the mini, this pane will most likely show "No LM Studio server
reachable" (§3's mockup state 4) or, worse, a *different*, empty/idle
local LM Studio instance if one happens to be running on the Air too —
both are honest, defined states, not crashes, but neither is useful for
watching mini-driven OpenCode traffic from the Air.

*Trade-off, stated in the UI itself (§3 state 4's copy):* the user's own
motivating scenario — watching a Mac mini's LM Studio while working from
wherever Batty happens to be running — is not fully served by this option
if Batty is ever run from the Air. Local-only is still recommended because
(a) it needs zero new infrastructure — no auth, no new network surface —
and everything in §1 was verified against exactly this topology; (b) it
avoids exactly the exposure the reference's `ai.sstools.co` warning is
about; (c) `#0313`'s own issue text already runs Batty on the mini today
in the primary use case it describes, so local-only is not a regression
from anything working now, only a documented ceiling on where else it
would work.

**Option B — Remote-capable.** Batty connects to a remote LM Studio (the
mini) over the network from wherever it runs. Technically plausible — the
WebSocket/REST interfaces don't inherently require same-machine — but
requires **building an authenticated path that does not exist today**,
which is real, unscoped infrastructure work (not a design decision this
document can make on its own): a way to reach the mini's LM Studio safely
from another Mac without exposing it unauthenticated, which is exactly
what the reference's Caddy/authentication warning is about. This document
does not design that path — it would be its own issue, gated on this one's
answer being "yes, build it."

**Recommendation: Option A (local-only) for phase 1.** Ship the simple,
already-verified topology; treat remote access as a distinct, explicitly
scoped future issue if the user confirms they want it, rather than
building unscoped auth infrastructure speculatively inside this view's
design. State the ceiling honestly in the UI (§3 state 4) rather than
silently failing.

---

## 3. What it shows

Bounded strictly by what §1 confirms is obtainable, and by the issue's own
explicit "not supported" list (live per-client token ticker, GPU/memory
utilization — `#0314` is the natural home for the latter, and its own
spike found system-wide memory readable but left per-process/GPU
utilization unresolved, same as this document leaves it; per-request
client identity/attribution — no source carries it).

1. **Header row** — "LM Studio Dashboard" kind chip, a connection-health
   pill (Connected / Reconnecting / No server — driven by whether the
   model-list poll and the log-stream subprocess are both currently
   healthy, §5), a manual refresh button, **plus the same pane-level drag
   handle and hide (eye) button every terminal Pane and every prior
   non-terminal Pane already has** — the identical header-level relocation
   `docs/design/git-status-view.md` §2 first justified (those two mouse
   affordances live inside the tab-bar `HStack` that only exists in
   `PaneView`'s `.terminal` arm per `docs/pane-kinds.md` §2). No
   "Choose Process…"/"Change Directory…" equivalent by default — like
   `system-metrics`, this pane's subject under §2.2's recommended
   local-only design is always "the local LM Studio server," nothing to
   retarget.
2. **Loaded Models panel** — one card per model with a non-empty
   `loaded_instances` entry (§1.6): display name, publisher, quantization,
   params, size, and per-instance `context_length`/`parallel` from the
   same `/api/v1/models` poll. A collapsed "N more available, not loaded"
   disclosure underneath lists the rest of the catalog on expand — not
   polled any more frequently for that purpose, since it's the same single
   poll response already fetched for the loaded set.
3. **Busy / Idle status row**, per loaded instance — see §4 for exactly
   which signal drives "generating" (the log stream's own in-flight count,
   not `lms ps`) and why; the pill shows Idle/Generating, a TTL countdown
   when `ttlMs` is non-null (§1.2 — `null` today, since no TTL is
   configured on this server, so the mockup shows both a set and an unset
   TTL), and Device (mapped from `deviceIdentifier`, falling back to
   "Local" when `null`, §1.2).
4. **Live Request feed** — two parts, visually distinct:
   - **In-flight** — unmatched `input` events, paired to instances by
     `modelIdentifier`, labeled honestly per §4's UI-language requirement
     ("In-flight — pairing is a best guess" with a `parallel > 1` caveat
     when relevant, not a bare list implying certainty).
   - **Recent completions** — newest-first, capped at **200 entries**
     (§6 — reusing the Bell Feed's own existing cap,
     `BellFeedStore.swift:124`, `public static let cap: Int = 200`, rather
     than inventing a new number). Each row: relative timestamp, model
     identifier, duration (`stats.totalTimeSec`), tok/s, TTFT, a
     stop-reason badge (`stopReason`), and a compact context-pressure
     percentage (`stats.promptTokensCount ÷` that model's
     `loaded_instances[].config.context_length` from the same poll, §1.6
     — computed per-row so it's unambiguous which model's context window
     is meant, rather than one global gauge). **No prompt or completion
     text in this default view** — per §2.1's Option A.
5. **Throughput mini-chart** — a tok/s sparkline and a stop-reason tally,
   both computed **client-side from the already-retained 200-entry ring
   buffer** (§6) — not a second data source, not a persisted long-term
   history. Bounded exactly by what's already in memory for the list
   above.
6. **Engine Errors & Warnings panel** — sourced from `-s runtime` only,
   by default, per §1.8's finding that `-s server` leaks request/response
   content at the default log level. A collapsed disclosure, not a
   permanently-visible panel, since it's empty in the common case.
7. **Non-mutating context menu** on a completion row: "Copy Model
   Identifier," "Copy Stats as JSON" (the `stats` block only — never
   `input`/`output`, matching §2.1's default). No mutating actions (no
   "Unload Model," no "Cancel Request") — nothing in the umbrella's user
   quotes asks for control, matching the read-only precedent
   `docs/design/git-status-view.md` §3 and `docs/design/
   process-status-view.md` §3.7 both already set for this pane family.

### What's deliberately not shown by default

Prompt/completion text (§2.1 — opt-in only, state 5). Live per-token
ticker for observed traffic (impossible per the issue's own constraint,
confirmed by §1.3 — `output` arrives whole). GPU/memory utilization
(`#0314`'s own spike ruled in system memory generally but left
GPU-specific and per-process utilization unresolved; nothing here
overturns that). Per-request client identity (no source carries it,
confirmed — §1.3/§1.8 both checked and found none). Server-log content
(§1.8 — excluded from the default Engine Errors panel specifically, not
merged into it).

---

## 4. Hard constraints, stated in the UI's own terms

The issue requires these be visible in the mockup's own language, not
buried in this prose:

- **No live token ticker.** The Recent Completions list shows a
  completion the instant its `output` event lands, whole — there is no
  streaming-text animation, no partial-completion state for
  other-client traffic. The mockup's "prediction in flight" state (§ below)
  shows a request as **pending** (an indeterminate progress affordance, not
  a token count ticking up) until its matching `output` arrives, then it
  snaps directly to the completed row — honest about what the feed
  actually delivers (§1.3: start event, then one finish event carrying
  everything at once).
- **In-flight pairing is a heuristic, said so in the UI, and the UI's own
  wording is calibrated to what was actually observed, not just what
  seems cautious.** Every in-flight row carries a small "best guess"
  indicator (an info glyph with the literal explanation: "Paired by model
  and arrival order — no request ID exists. With more than one prediction
  running on the same model, this pane can't always tell which reply
  belongs to which request — and has been observed to get it wrong, not
  just be unable to confirm it."), not silently presented as certain.
  §1.4 empirically reproduced two concurrent inputs landing at the
  identical millisecond timestamp on this exact server, and review round
  1's independent re-run of the same experiment observed the two
  corresponding outputs return in the **opposite order** from their
  inputs — a live mispairing, not merely an unconfirmable simultaneity.
  This isn't a hedge against a hypothetical; it's a documented, reproduced
  failure mode of the only pairing signal that exists, observed to
  actually mispair at least once, not just theorized to be capable of it.
- **The alpha/API-stability risk is recorded, and designed around, not
  just footnoted.** §5 picks the CLI-subprocess transport specifically
  *because* `unstable_streamLogs` (the SDK path) is marked alpha
  ("Do not use this method in production yet," carried from the
  reference — see §1.9). The connection-health pill's "Reconnecting"
  state exists partly because a CLI subprocess can die and needs restart
  logic a stable, non-alpha API wouldn't need as urgently — naming the
  dependency's own instability as a reason this pane's design includes a
  visible degraded state, not just a footnote about the SDK.
- **Retention is designed, not deferred** — see §6, with concrete numbers
  traceable to §1's measurements and the existing `BellFeedStore.cap`
  precedent, and explicit hide/teardown behavior per
  `docs/pane-view-lifecycle.md`.

---

## 5. Data collection architecture and cadence

**Transport: CLI subprocess (`lms log stream --json --stats`), not the SDK
`unstable_streamLogs`.** Following `docs/design/git-status-view.md` §4's
own precedent for spawning `git` via `Foundation.Process`, and specifically
*because* of the alpha warning on the SDK method (§1.9, §4) — the CLI is
what the SDK's own alpha method wraps, per the reference, so using the CLI
directly avoids depending on the less-stable of the two paths to the
identical feed. Two concurrent subprocesses run, matching §1.8's confirmed
multi-source finding:

- `lms log stream --json --stats -s model` — the primary feed (§3's Live
  Request panel).
- `lms log stream --json -s runtime` — the Engine Errors panel (§3.6),
  **not** `-s server`, per §1.8.

Both parse NDJSON off the main thread, skipping the banner/blank-line
prefix (§1.3), the same "never block the main actor on subprocess I/O"
discipline `docs/design/git-status-view.md` §4 already establishes for its
own `git status` subprocess.

**Polling, two different cadences, split by §1's own cost measurements —
not a single shared interval the way the sibling views (whose per-tick
cost was uniformly negligible) could get away with:**

| Source | Cost (§1) | Cadence | Role |
|---|---|---|---|
| `GET /api/v1/models` | ~11 ms/call | 1 s | Primary: loaded-set, per-instance context/parallel config, diffed to synthesize load/unload transitions (no push event exists, §1.1/reference) |
| `lms ps --json` | ~157 ms/call | **3 s** | Secondary enrichment only: `deviceIdentifier`, `ttlMs`, and an authoritative cross-check of busy/idle — **not** the primary "is it generating" signal |

**Busy/idle's primary signal is the log stream's own in-flight count
(§3.3/§4), not `lms ps` polling — a deliberate design choice this document
makes because of §1.7's cost finding, and worth stating precisely why it's
still correct, not just cheaper.** An unmatched `input` event *is* "a
prediction is running" — that's the same fact `lms ps`'s `generating`
status reports, just derived from a push signal already being consumed for
the Live Request panel instead of a second, 157-ms-per-call poll. Using it
as primary means the busy/idle pill updates in near-real-time (the instant
an `input` event arrives) rather than waiting up to 3 seconds for the next
`lms ps` tick. The slower `lms ps` poll still runs, because it's the
*only* source for `deviceIdentifier`/`ttlMs` and provides an independent
cross-check against the heuristic pairing (§1.4) — if `lms ps` ever
reports `idle` while the log-stream-derived state still shows an
unresolved in-flight entry (a plausible symptom of the exact pairing
ambiguity §1.4 found), the UI prefers `lms ps`'s authoritative read and
visibly clears the stale in-flight row, logging the discrepancy rather
than leaving two contradictory signals on screen indefinitely.

**Connection health**: the SDK's `system.whenDisconnected()` (reference
§2, not independently re-tested — carried, low-risk, since this design
doesn't use the SDK transport anyway) is not used; connection health here
is a direct consequence of subprocess liveness (are the two `lms log
stream` processes still running) and poll success (is the last
`/api/v1/models` poll within its expected window) — both already-owned
signals, no new dependency.

**Degraded cadence when the server is unreachable — settled here, not left
implicit.** `issues/0313.md`'s own Gotchas require a defined degraded
state for "not installed, not running, and version-drifted," not a crash
or an indefinite spinner; state 4's mockup (§9) shows the *visual* result,
but review round 1 correctly found this document didn't previously say
what the 1 s/3 s polls in the table above actually *do* once the server
stops answering — an omission that left the mockup's own "no background
retry loop" claim (state 4) contradicting a design that, read literally,
never stops polling. Fixed:

- **A single failed poll does not flip the connection-health pill.** The
  `/api/v1/models` poll must fail **twice in a row** (roughly a 2-second
  window at the 1 s cadence) before the pane declares the server
  unreachable — a lone dropped request or a momentary hiccup shouldn't
  flicker Connected → No server → Connected.
- **On declaring unreachable**: both `lms log stream` subprocesses are
  terminated (the same bounded-wait `SIGTERM` sequence §7's `tearDown()`
  row uses, since there is nothing for them to stream from a server that
  isn't answering, and leaving them running would mean two subprocesses
  independently retry-looping against a dead endpoint at a rate this
  design doesn't control), and the `lms ps` poll stops entirely — no
  157 ms/call CLI invocations fired against a server known to be down.
  The `/api/v1/models` poll **does not stop** — it backs off from 1 s to a
  fixed **5 s reachability-only cadence**, the lightest available probe
  (§1.7: ~11 ms/call), so the pane recovers on its own once the server
  comes back rather than requiring the user to notice and act. This is
  the "back off to X" shape, not "stop" or "keep ticking at 1 Hz" — the
  three options review round 1 named as the ones this section needed to
  choose among.
- **On the first successful reachability probe after a backoff**: resume
  the full 1 s/3 s cadence, respawn both `lms log stream` subprocesses,
  and perform one immediate `/api/v1/models` refresh — the same
  "showing resumes and refreshes" shape `docs/pane-view-lifecycle.md` §4
  already requires of `setVisible(true)`, applied here to a
  reachability recovery rather than a visibility change.
- **Existing in-flight rows are not cleared just because the server
  becomes unreachable.** A brief network blip shouldn't erase a
  genuinely in-flight prediction from the display; they fall back to
  §6's existing 5-minute staleness eviction like any other in-flight
  entry, rather than being force-cleared the instant a poll fails.
- **The header's manual refresh/"Retry" affordance (§3, §9 state 4)
  triggers an out-of-cycle reachability probe immediately** — the same
  `/api/v1/models` call the 5 s backoff loop would eventually make on its
  own, just not waiting for the next scheduled tick. It is **not** a
  re-invocation of `setUp()` — under `docs/pane-view-lifecycle.md` §3's
  state machine, `setUp` is the one-shot `notSetUp →` transition and is
  not legal to call a second time (a repeat call is `.rejected`, logged
  at `.error`, per that document's own contract). Naming the mechanism
  precisely here so the mockup doesn't misattribute it either — see §9's
  note for the corresponding fix.

**Phase-2 obligation, named here rather than redesigned now:** review
round 1 flagged that the `lms ps` cross-check described above (the
paragraph before this one — "if `lms ps` ever reports `idle`... visibly
clears the stale in-flight row") can itself clear a *legitimately*
in-flight row if the `lms ps` sample (which the spike measured taking
~130-160 ms to return, §1.7) was captured *before* a prediction that
started only moments earlier — the sample's own snapshot can be stale
relative to a request that began during the ~150 ms the CLI call was
still running. This document does not redesign the cross-check to fix
that now; it names the fix phase 2 must apply: gate the clear on
comparing the `lms ps` sample's own timestamp against the in-flight
entry's recorded start time, and only clear entries that started before
the sample was taken, not every unresolved entry indiscriminately.

---

## 6. Retention design

**Default (Option A, §2.1) — no prompt/completion text is ever retained,
full stop.** The NDJSON parser reads each event, extracts the `stats`
block and metadata fields, and discards the `input`/`output` string
immediately after parsing — it is never copied into any retained
structure. This is stronger than "capped small": for the default
configuration, the sensitive fields' retained footprint is exactly zero,
independent of any cap number.

**Recent Completions ring buffer: 200 entries, matching
`BellFeedStore.cap` (`BellFeedStore.swift:124`) exactly, not a new
number invented for this view.** Per entry: timestamp, model identifier,
duration, the `stats` block's numeric/string fields (tok/s, TTFT, prompt/
predicted/total token counts, stop reason) — no `input`/`output`. At a
generous per-entry estimate (a few hundred bytes of numbers and short
strings), 200 entries is on the order of tens of KB total, nowhere near
the growth class `#0285` is the standing warning about.

**In-flight tracking is bounded by construction, not by an explicit cap**:
the number of truly outstanding predictions per instance is bounded by
that instance's own `parallel` config (§1.6 — `2` on the verified
instance), typically single digits across the whole server. A staleness
guard still applies: an in-flight entry with no matching `output` within a
bounded window (e.g. 5 minutes — long enough that no real prediction on
any reasonable hardware should still be running, short enough to recover
promptly from a dropped/reconnected log-stream subprocess losing an
`output` event) is evicted from the in-flight display rather than kept
forever — named explicitly because §1.4's own concurrent-request test
shows exactly the ambiguity that could otherwise leave a phantom in-flight
row stuck on screen indefinitely after a subprocess restart.

**Prompt Inspector opt-in (§2.1 Option A's toggle, state 5): a separate,
much smaller ring, not the same 200-entry cap.** When enabled, the last
**5** predictions' raw `input`/`output` text are retained (LRU-evicted),
deliberately an order of magnitude smaller than the metadata cap — at
§1.5's confirmed tens-of-KB-per-event scale, 5 entries bounds the
worst case to roughly 100–150 KB rather than the multiple-MB a matching
200-entry raw-text cap would risk. Turning the inspector off clears this
ring immediately, not just stops adding to it — an explicit action that
mirrors `tearDown()`'s own "release everything now, not eventually"
discipline (§7) applied to a user-initiated privacy action, not just the
pane's own lifecycle events.

**Hidden-pane behavior: discard, not keep — following `#0305`/`#0314`'s
own precedent (`docs/design/system-metrics-view.md` §4, "discard, not
keep") rather than inventing a different answer.** `setVisible(false)`
tears down both log-stream subprocesses and the model/`lms ps` poll
`Task`s, and **also discards the Recent Completions ring buffer and any
Prompt Inspector text** — not just stops adding to them. This is a real,
named departure from what "discard" costs for the sibling views:
`process-status`/`system-metrics` can resample their entire current state
in milliseconds on `setVisible(true)`, so discarding loses nothing a user
can perceive; **this view's recent-predictions history cannot be
cheaply resampled** — it's a log of what already happened, not a
snapshot of current state, so discarding it on hide means a user who hides
and reshows the pane sees an empty feed until new predictions occur, a
real (if modest) loss of continuity `process-status`/`system-metrics`
don't have an equivalent of. This document accepts that cost deliberately
rather than building a "keep a bounded history across suspend" exception,
for reasons specific to this project's own stated priorities: `#0303`'s
own framing names `#0285`'s 8.4 GB retrofit as the standing argument for
"a non-terminal kind should default to releasing everything it can, not
just what's convenient," and nothing in the umbrella's user quotes asks
for a durable history survivable across a hide — "a live view into what is
happening" (the user's own words, `issues/0313.md`) is satisfied by a feed
that's live while visible, not one that's also a persistent audit log.
**Not designed here, named as available for a future issue if wanted**:
the reference's own §1 mentions rotating log files at
`~/.lmstudio/server-logs/YYYY-MM/` that could back-fill history on
re-show or first open — this document doesn't build that, both because
§1.9 didn't verify those files' format or availability and because it
would reopen exactly the "how much history, retained how" question this
section just closed by choosing zero.

---

## 7. Lifecycle wiring — the `PaneContentLifecycle` contract, concretely

`LMStudioDashboardPaneContent` conforms to `PaneContentLifecycle`
(`BattyKit/Sources/BattyKit/Runtime/PaneContentLifecycle.swift:110-138`,
confirmed current) via a `PaneLifecycleController`
(`PaneContentLifecycle.swift:146-161`), the same shape every sibling view
commits to:

| Contract method | What it does here |
|---|---|
| `setUp(visible: Bool)` (`PaneContentLifecycle.swift:123`) | Runs one `/api/v1/models` poll immediately (§1.6, ~11 ms) so the Loaded Models panel has something to show the instant the pane exists. If `visible == true`: additionally spawns both `lms log stream` subprocesses (§5), starts the 1 s models-poll `Task` and the 3 s `lms ps` poll `Task`. If `visible == false`: stops there — no subprocess spawned, no poll `Task` started, matching the direct `notSetUp → suspended` edge `docs/pane-view-lifecycle.md` §3's state diagram requires — "setup must not create work it would immediately have to suspend" (§4 of that document). |
| `setVisible(true)` (`suspended → active`, `PaneContentLifecycle.swift:130`) | (Re)spawns both subprocesses (they don't exist yet — suspended means fully torn down, not paused, matching `docs/design/git-status-view.md`'s own FSEventStream precedent) and restarts both poll `Task`s, performing one immediate refresh of each, matching "showing resumes and refreshes" (`docs/pane-view-lifecycle.md` §4). Per §6, the Recent Completions ring and any Prompt Inspector text start empty — this is the concrete mechanism behind §6's "discard, not keep" decision, not a separate implementation detail. |
| `setVisible(false)` (`active → suspended`) | Sends `SIGTERM` to both `lms log stream` subprocesses (`Process.terminate()`) and cancels both poll `Task`s. Per §6, also clears the Recent Completions ring buffer and any Prompt Inspector text immediately — hiding is where the discard happens, not a separate step. No bounded wait here (matching `docs/design/process-status-view.md`'s distinction between `setVisible(false)` and `tearDown()`) — hiding needs to stay cheap for a fast session switch; only `tearDown()` carries the synchronous-release obligation, per the next row. |
| `tearDown()` (`PaneContentLifecycle.swift:137`) | Same subprocess termination and poll cancellation as `setVisible(false)`, plus a **bounded wait** on both subprocesses actually exiting — the same trade-off `docs/design/git-status-view.md` §4 names for its own `git status` subprocess: `Process.terminate()` alone only sends `SIGTERM` and returns immediately, which is not evidence of release (the `#0289` lesson, generalized by `docs/pane-view-lifecycle.md` §5); an unbounded `waitUntilExit()` risks hanging the main actor if a subprocess is ever wedged. `tearDown()` sends `SIGTERM` to both, then polls `Process.isRunning` with a short, fixed bound (a few hundred milliseconds — `lms` is a normal CLI process that should die promptly on `SIGTERM`, not a case expected to need the bound in practice), logging a warning and returning anyway if the bound is hit rather than blocking indefinitely. Idempotent, per the state machine's `.noOp` handling of a repeated `tearDown` (`docs/pane-view-lifecycle.md` §3). |

**What "suspended" costs**, per `docs/pane-view-lifecycle.md` §4's "zero
periodic work" requirement: zero — no running subprocess, no scheduled
poll `Task`, and (per §6) no retained prediction history either. This is
a stricter "suspended" than the sibling views need to be (their suspended
state has zero periodic work but nothing analogous to discard, since they
retain no cumulative history in the first place) — here, zero periodic
work *and* zero retained data are two separate commitments this document
makes together, both traced to `#0303`'s "total freedom to release, use
it" framing.

**Where the calls come from**: unresolved by this document, the same way
every sibling leaves it — `docs/pane-view-lifecycle.md` §5's open item on
`showPane`'s asymmetry (`WindowRuntime.hidePane` drives the terminal path
directly; `showPane` relies on remount instead) is phase 2's shared wiring
question, not re-litigated per view. `LMStudioDashboardPaneContent
.setVisible` must be safe to call redundantly or via a remount-driven
path, because `docs/pane-view-lifecycle.md` §3 requires `.noOp` idempotence
at the state-machine level regardless of caller — the same commitment
every sibling view makes.

---

## 8. Shared infrastructure with `#0305`/`#0314`

**Genuinely little is shared, and this document says so rather than
forcing a connection.** `#0305`/`#0314` share a per-pid libproc sampling
primitive because both read the same in-process kernel calls against the
same struct layouts (`docs/design/system-metrics-view.md` §5). This view's
data sources — HTTP JSON polling and NDJSON subprocess parsing — are a
different technology stack entirely, with no struct-layout or syscall
overlap to factor out.

**What is worth sharing, narrowly:**

- **The bounded-wait subprocess-teardown pattern** (`Process.terminate()`
  + a short polled bound on `Process.isRunning`, not `waitUntilExit()`) is
  now needed by two views independently — `git-status`'s `git status`
  subprocess and this view's two `lms log stream` subprocesses. Worth a
  small shared helper (naming left to phase 2, the same way
  `docs/design/system-metrics-view.md` §5 leaves `ProcessMetricsReader`'s
  name to its own phase 2) rather than three independent copies of the
  same bounded-poll loop once this view's phase 2 lands.
- **The `BellFeedStore.cap = 200` convention** (§6) is reused as a value,
  not as shared code — there's no reason for this view's ring buffer to
  literally share a type with the Bell Feed's, since the entry shapes are
  unrelated, but reusing the *number* rather than picking a new one keeps
  the app's few in-memory caps consistent for a user who might reasonably
  ask "why 200."

**What's explicitly not shared**: `#0314`'s SMC/thermal/system-memory
readers, `#0305`'s per-pid libproc sampler — none of it applies here, and
this document doesn't force an artificial connection where §1's spike
found none.

---

## 9. Mockup states

Five states, matching the issue's explicit list:

1. **Idle server, models loaded** — Loaded Models panel populated, Busy/
   Idle pill shows Idle for the one loaded instance, Recent Completions
   has a modest history, no in-flight rows.
2. **Prediction in flight** — an in-flight row with the "best guess"
   pairing caveat visible (§4), Busy/Idle pill shows Generating, no token
   ticker (§4) — an indeterminate pending affordance instead.
3. **Completed prediction with stats** — the same request from state 2,
   now a Recent Completions row with tok/s, TTFT, stop reason, and
   context-pressure percentage all populated from a real captured event
   shape (§1.3).
4. **No LM Studio server reachable** — connection-health pill reads "No
   server," an empty-state body naming what was tried (`localhost:1234`)
   and, per §2.2's recommendation, an explicit note that a remote server
   (e.g. a Mac mini) is not supported in this phase — surfacing §2.2's
   ceiling in the UI itself, not just this document's prose.
5. **Prompt Inspector — opt-in, clearly marked** — the same completed
   request as state 3, with the inspector toggle visibly on, a persistent
   banner distinguishing this state from every other ("Prompt Inspector is
   ON — showing raw prompt and completion text for the last 5 predictions
   only"), and the raw `input`/`output` text rendered — demonstrating both
   that the feature exists and that it is never the default a user lands
   on unintentionally.

---

## Summary table (quick reference for phase 2)

| Question | Answer | Section |
|---|---|---|
| Are the reference's interface claims still true? | Mostly, with three real corrections: `/api/v0/events` and `/` return HTTP 200 with an error body, not literal 404 (conclusion unaffected); `stats` appears in log-stream output events even without `--stats` on this CLI build (still pass `--stats` defensively); `lms ps --json` costs ~157 ms/call, not free (shapes the polling design in §5). Two new findings the reference doesn't report: `-s` accepts one source per invocation, requiring multiple concurrent subprocesses; `-s server` leaks full request/response content at the default `info` log level, so the Engine Errors panel sources from `-s runtime` only. | §1 |
| Show prompt/completion text? | Recommended: off by default, explicit per-pane opt-in ("Prompt Inspector"), tighter retention (5 entries, not 200) than the metadata feed, sourced only from `-s model` never `-s server`. | §2.1 |
| Local-only or remote-capable? | Recommended: local-only for phase 1. Remote requires unscoped authenticated-transport work this document doesn't design; this spike ran on the mini itself and adds no evidence on Air-visibility, which remains untested exactly as the reference states. | §2.2 |
| What does it show? | Loaded models, busy/idle+TTL+device, in-flight + recent-completions feed (metadata only by default), a throughput sparkline and stop-reason tally computed from already-retained data, an Engine Errors disclosure (`runtime` source only). No live token ticker, no GPU utilization, no per-request client identity — none of those are supported by any interface. | §3 |
| How is data collected? | Two concurrent `lms log stream` CLI subprocesses (`model`+`stats`, and `runtime`) — not the alpha SDK method. `/api/v1/models` polled at 1 s (cheap, ~11 ms/call). `lms ps --json` polled at 3 s, as a secondary enrichment/cross-check only — busy/idle's primary signal is the log stream's own in-flight count, because `lms ps` measured at ~157 ms/call is too expensive to be the 1 Hz primary source the sibling views could afford for their own near-free data. | §5 |
| Retention? | Zero for prompt/completion text by default. 200-entry metadata ring (reusing `BellFeedStore.cap`). In-flight bounded by `parallel` config plus a 5-minute staleness eviction. Inspector opt-in: a separate 5-entry raw-text ring, cleared immediately when toggled off. Everything discarded on hide, not just suspended — a real, named continuity cost this view accepts that the sibling views don't have to. | §6 |

---

## Verification for this issue

**Documentation and a static HTML mockup only — no Swift source changed,
no `PaneRuntime`/`PaneView`/`PaneContentKind` touched.** The verification
spike (§1) ran as direct `curl`/`lms` CLI commands against the live LM
Studio server and is not part of this commit.

```
scripts/build.sh unit
```

`Configuration/Active.xcconfig` read `#include "Prod.xcconfig"` before
running — Prod, not Beta. Baseline check only, since this document
introduces no Swift source at all.

The companion mockup, `docs/design/lmstudio-dashboard-view.html`, is a
self-contained (no network requests, no external resources) HTML file
matching the sibling designs' visual language, covering the five states
in §9.

### What phase 2 additionally owes, made visible before approval

Identical obligation the three sibling designs already name for their own
phase 2, because all four land in the same shared `PaneView`/`PaneRuntime`
path: **whichever issue first lands the `PaneContentKind` field and
`PaneView`'s kind-switch** must re-run the full manual checklist in
`docs/terminal-pane-requirements.md` §6 on **terminal** panes generally,
and again on a **terminal** pane in a **mixed-kind session** — this
document's phase 2, landing after the others, inherits the already-paid
cost for the mechanism itself but should still verify a terminal pane
alongside an `lm-studio-dashboard` pane specifically, per that document's
own "fine in isolation, wrong in composition" reasoning. **Additionally
specific to this view**: phase 2 must re-verify §1.8's `-s runtime`
content-safety gap (not checked in this spike, named as open) before
shipping the Engine Errors panel as privacy-safe-by-default, and must
re-confirm §1's CLI-behavior findings (especially the `--stats`-optional
observation, §1.3) against whatever `lms` build is installed at
implementation time, since the reference itself demonstrates this
surface can drift between verification and implementation. **Also
specific to this view, flagged by review round 1 and not fixed in this
round (§5):** the `lms ps` cross-check that clears a stale in-flight row
when `lms ps` reports `idle` must gate that clear on the `lms ps`
sample's own timestamp versus the in-flight entry's recorded start
time — not clear indiscriminately — because the sample itself takes
~130-160 ms to return (§1.7) and can be stale relative to a prediction
that started moments before it was taken, which would otherwise let the
cross-check clear a row that is, in fact, still genuinely in flight.

---

*Document version: 1 — 2026-08-09. Written for `#0313` phase 1. No code
changes accompany this document except the verification spike (§1), which
ran as direct commands against a live LM Studio server and is not part of
this commit. Phase 2 (implementation) is gated on user approval of this
document and its companion mockup, per the `#0301` umbrella's design-first
gate, and additionally on the user's explicit answers to §2.1 and §2.2,
which this document recommends but does not decide.*
