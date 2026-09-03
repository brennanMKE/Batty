# Agent workflows with the `batty` CLI

This guide shows agents and scripts how to control Batty reliably. For the
complete command reference, installation details, transports, and exit codes,
see [`batty-cli-install.md`](batty-cli-install.md).

## Prerequisites

- Install the CLI from Batty → Settings → Advanced. Prod installs `batty`;
  Beta installs `batty-beta`.
- Enable Batty's broker Login Item if macOS asks. `batty ping` must succeed
  before any XPC-backed command can run.
- Install [`jq`](https://jqlang.github.io/jq/) for the deterministic JSON
  topology recipes below.

Check the setup:

```sh
command -v batty
batty --version
batty ping
batty status
```

`ping` checks the broker, while `status` confirms the app can answer through
the complete broker → app-endpoint connection.

## Target resolution: always know which Pane will change

Commands that accept a target resolve it in this order:

1. Explicit `--session`, `--pane`, or `--tab` flag.
2. The matching `BATTY_SESSION_ID`, `BATTY_PANE_ID`, or `BATTY_TAB_ID`
   inherited by a process running inside a Batty terminal.
3. Batty's currently focused element.

Agents should prefer explicit IDs. Environment IDs are useful inside an
existing Batty Pane, but they keep pointing to that original Pane after the
agent creates a different Session. Focus is user-controlled and can change at
any moment.

Use these commands to discover IDs:

```sh
batty id                 # local BATTY_* context; no app connection
batty id --json
batty list sessions
batty list panes
batty list tabs
batty list --json        # complete topology for scripts
```

## Create a project Session with command Panes to its right

The goal is this layout:

```text
project shell | command 1 | command 2 | ...
```

`batty new <path>` (#0380) snapshots topology over XPC *before* dispatching
the `batty://` URL, dispatches exactly as before, then polls topology until
exactly one Session appears whose path matches the resolved directory and
whose id was not in the snapshot — path alone isn't enough, since the user
may already have a Session open on that directory. If Batty wasn't running
yet, the snapshot is trivially "no Sessions" and the poll budget is larger,
since `open` still has to launch the process and it has to register with
the broker before Session creation even starts — but a cold launch also
creates its own default Session (usually at `$HOME`, `docs/batty-cli-install.md`'s
end-to-end trace covers this), so requesting `$HOME` itself (`batty ~`, bare
`batty`/`batty .` run from home) can make *two* Sessions match. When both
are visible **at once** with resolved paths, the poll waits rather than
guessing which one is new, and reports the ambiguity explicitly (see the
last failure mode below) if it never resolves to exactly one. This does
not cover every ordering, though: the default Session's path can resolve,
and be the only visible match, before the requested Session appears in
topology at all (or the request can be dropped outright, #0251) — in that
narrow window `batty new ~` can still report the default Session's id with
no ambiguity signal. See `issues/0380.md`'s `## Gotchas` for the accepted
residual. Once found, `batty new` prints the new Session id
on line 1 and its `focusedPaneID` on line 2 (or `{"sessionID": "…",
"paneID": "…"}` with `--json`), so an agent no longer has to snapshot and
poll itself. `--no-wait` skips all of this and reverts to the original
one-way, no-confirmation behavior — for scripts that already have their own
way to identify the Session, or that genuinely don't care, and for the
interactive `batty .` habit where nobody is scripting against the output:

```sh
new_output=$(batty new "$HOME/Developer/MyApp"); status=$?
if [ "$status" -ne 0 ]; then
    echo "batty new failed (exit $status)" >&2
    exit "$status"
fi
pane_id=$(printf '%s\n' "$new_output" | tail -1)
if [ -z "$pane_id" ]; then
    echo "batty new created a session but did not report an id (degraded path — see below)" >&2
    exit 1
fi

for command in "npm run dev" "npm test -- --watch"; do
    pane_id=$(batty pane split --horizontal --pane "$pane_id" \
        --command "$command") || exit $?
done
```

`--horizontal` creates a left/right split and the returned ID belongs to the
new right-hand Pane. `--command` replaces the configured shell for that Pane
and keeps the Pane open after the command exits so its output remains
visible. Capture `batty new`'s exit status separately from its output — piping
straight into `tail -1` (or any consumer) discards the exit code and hides a
failure, including the degraded case below where stdout is legitimately empty.

**Four failure modes are specific to `batty new`:**

- **Degraded (exit `0`, no stdout):** if the pre-dispatch check couldn't
  establish that Batty was cleanly not-running (broker unreachable) or
  cleanly running-and-registered (app running but the broker has no
  endpoint for it — a state a launch would only duplicate, not fix), there
  is no reliable snapshot to diff against, so the CLI cannot safely identify
  which Session is the new one. It still dispatches the URL (the Session is
  created) and exits `0`, but prints nothing on stdout and writes a one-line
  note to stderr instead of guessing. An agent whose script assumes
  non-empty stdout on success should check for this rather than treat empty
  output as failure.
- **Poll timeout while Batty was reachable (exit `4`):** if an XPC endpoint
  was live at some point during the poll — Batty was already running, or a
  cold launch registered before the session-match poll ran out — but the
  poll never saw the new Session appear within its budget, `batty new`
  exits `4` (the same "request failed" code other mutating verbs use)
  rather than hanging or inventing a new code. **This is not the same
  situation as a `4` from another verb:** `list` kept succeeding the whole
  time, so the app never rejected anything — the Session may have been
  created and just didn't show up before the poll gave up. Refresh topology
  (`batty list --json`) and look for it by path; do not re-run `batty new`,
  which would create a duplicate Session.
- **Cold-launch timeout with no endpoint ever seen (exit `3`, or `2` if
  the *last* poll attempt found the broker itself unreachable):** if Batty
  was not running before dispatch and no XPC endpoint ever came up within
  the (larger) cold-launch poll budget, `batty new` exits `3` ("app
  unavailable") — the same code every other verb uses when the broker
  answers but no app ever registers. If the broker's response to the
  *final* attempt was "unreachable" specifically — rather than "reachable,
  but no endpoint registered yet" — the exit is `2` ("broker unreachable")
  instead, the same distinction every other XPC-backed verb makes. (Only
  the last attempt is checked, not the whole history: a poll where the
  broker was briefly unreachable mid-run but answered normally on the
  final attempt still exits `3`.) Unlike the exit `4` case above, `list`
  never succeeded even once during the poll, so there is no evidence the
  Session was ever created. Check whether Batty is installed and
  launchable (`batty ping`, `batty status`) before retrying.
- **Persistent ambiguity with a cold-launch default Session (exit `4`):**
  requesting `$HOME` itself while Batty is not running can make *two*
  Sessions match the poll's criteria at once — the default Session a cold
  launch also creates, plus the requested one (see above). `batty new`
  never guesses here: if the ambiguity never resolves to exactly one match
  before the poll's budget runs out, it exits `4` with a distinct "multiple
  sessions matched" message on stderr instead of printing either id.
  Refresh topology and disambiguate manually rather than re-running
  `batty new`, which would add a third Session to the pile.

Any other XPC failure during the pre-dispatch check or the poll (broker
unreachable, app unavailable, app terminated, running but unregistered, or
bundle unresolved) surfaces through the same exit codes documented below.

Two agents racing `batty new` on the same path at the same time still
can't be told apart — there's no client-supplied token to disambiguate
them — but the ambiguity guard (`#0380` round 3 review, B1) changed the
likely outcome. If neither agent's dispatch has landed before the other's
pre-dispatch snapshot, each agent's own snapshot excludes only its own
pre-existing Sessions, so both new Sessions look "new" to both agents'
polls; the guard treats that as unresolvable ambiguity and both callers
time out at exit `4` rather than silently swapping ids. A silent swap is
still possible in principle if the two dispatches are far enough apart
that one agent's snapshot ends up including the other's already-created
Session (making it look pre-existing, not new, to that agent) — narrower
than before this issue, not eliminated. Avoid racing `batty new` against
the same directory from parallel agents regardless.

## Simpler workflow inside the current Pane

When an agent only needs to split the Pane it is already running in, Batty's
injected context is enough:

```sh
batty id
right_pane=$(batty pane split --horizontal --command "npm run dev")
batty pane split --horizontal --pane "$right_pane" --command "npm test -- --watch"
```

The first split targets `BATTY_PANE_ID`; the second explicitly targets the
Pane returned by the first command. Do not use this shortcut after `batty new`
because the inherited environment still identifies the old Pane — use the
pane id `batty new` itself prints instead (see above).

## Idempotent setup: re-running safely with `--unique`

Both workflows above call `batty pane split` unconditionally, so re-running
the same script — after a retry, a restart, or just running it twice by
habit — stacks a second identical Pane next to the first every time. An
agent that opens a status view as part of its own setup step, rather than
as a one-shot action a human triggered once, wants find-or-create instead:

```sh
git_status_pane=$(batty pane split --view git-status --unique) || exit $?
```

Safe to run any number of times: the first call creates the Pane; every
call after that finds the same **visible** git-status Pane already in the
target Session and returns its id without creating anything, so `batty
list --json` never grows a second Git Status Pane just because the setup
step ran again. `--unique` only matches within the target Session (not the
whole app), only a Pane the user can currently see (a hidden one doesn't
count — see `pane show`), and it doesn't care whether a matching Pane was
pointed at a different `--path`; see `docs/batty-cli-install.md`'s
`--unique` entry for the full match rule and its two asymmetries (co-supplied
flags are ignored on a match; an app predating this flag ignores `--unique`
entirely and always creates, though the CLI warns on stderr when it detects
that case). "Safe to run any number of times" describes the Pane it returns,
not necessarily the rest of the layout: an ordinary (non-`--unique`) split
moves focus to the new Pane only when the split target was already focused,
so the first run of a setup script can yank focus to the new dashboard while
a second run — hitting `--unique`'s match path, which creates nothing —
leaves focus exactly where it was. Chaining is unaffected either way, since
a following command targets by `--pane`/env, never by focus.

## Showing the human what you did: `notify` tells, `focus` shows

`batty notify` posts to the Bell Feed and hopes the human clicks it. `batty
{session,pane,tab} focus` brings the relevant Session/Pane/Tab and Batty's
window in front of the human directly — the pair from `#0381` closes the gap
`notify`-alone leaves. A typical sequence after opening a Pane the human
should see:

```sh
new_pane=$(batty pane split --horizontal --command "npm run dev")
batty notify --title "Dev server starting" --tab "$new_pane"
# ... later, once something needs the human's attention ...
batty pane focus "$new_pane"
```

`notify` attributes the Bell Feed entry to a Tab (`--tab <id>`), while focus
verbs take a Pane/Session/Tab id directly. All three focus verbs are
activating even when their target lives in a background Session or window —
the CLI's one sanctioned exception to "a mutation aimed at a background
Session must not switch the active Session" (#0257's 2026-07-27 terminology
amendment). `pane focus`/`tab focus` also un-hide their target if it was
hidden — focus must never land on a Pane the human can't see (#0256).

A `batty watch` subscriber should read the `session_focused`/`pane_focused`/
`tab_focused` events as "a `batty {session,pane,tab} focus` call ran", not as
"the focused Session/Pane/Tab changed" — they fire only from these CLI
verbs (clicks, tab chips, and keyboard shortcuts emit nothing), and a no-op
focus (already-focused target) still emits.

Semantics recap:

- `batty session focus <id>` — selects the Session and activates its window.
  No Pane/Tab side effects. Id-based targeting only; `<name>` is not
  implemented.
- `batty pane focus <id>` — focuses the Pane, leaving its selected Tab
  unchanged. Directional targeting (`up`/`down`/`left`/`right`) is
  deliberately deferred; only id-based targeting is implemented.
- `batty tab focus <id>` — selects the Tab if it isn't already active, and
  implies focusing its containing Pane. Id-based targeting only; `<n>`
  (index-based) is not implemented.

## Cleaning up what you created: `session close`, `pane hide`, `pane show`

An agent that opened a Session for a task, or split status Panes into it,
should be able to reverse that from the CLI too — not leave the Session
sitting in the sidebar or the Pane sitting visible for a human to dismiss by
hand. `#0382` closes that gap:

```sh
batty id                                  # confirms BATTY_SESSION_ID/BATTY_PANE_ID
git_pane=$(batty pane split --view git-status --unique)
# ... work happens ...
batty pane hide --pane "$git_pane"        # tuck it away without destroying it
batty pane show "$git_pane"               # bring it back later
batty session close                       # done — falls back to BATTY_SESSION_ID
```

`session close` and `pane hide` resolve their target through the same
chain as every other targeted verb (explicit flag → `BATTY_*` env → the
focused element). `pane show` is the one exception in the whole CLI:
**it requires an explicit `<pane-id>` and never falls back to
`BATTY_PANE_ID` or the focused Pane** — a hidden Pane has no shell a
`batty` call could be running from, so there is no "focused element" to
resolve. Get hidden Pane ids from `batty list --json`, which already flags
them (`"hidden": true`).

`pane hide`/`pane show` are idempotent: hiding an already-hidden Pane, or
showing an already-visible one, succeeds quietly (exit `0`) rather than
erroring — a setup/cleanup script doesn't need to track visibility state
itself. `pane hide` does refuse (exit `4`) when the target is its
Session's only visible Pane: a Session must always show at least one Pane,
so there is nothing to hide it behind.

`session close` can also refuse (exit `4`, with a distinct stderr message
per cause): an unknown/stale id; a Session holding a Tab that still needs
confirmation to close, which XPC has no UI to present (there is
deliberately no `--force` flag to bypass this — see `pane close`'s own
`#0283` note); and closing what would be Batty's very last Session, so an
agent script cannot chain a single command into quitting the app with no
confirmation dialog. Check `batty list --json`/`batty session info` before
retrying a refused close rather than looping blindly.

None of these three verbs activate Batty's window or change the selected
Session/Tab, even when the target is a background Session — that
focus-stealing exception is reserved for the `focus` verbs above (#0257).
A `batty watch` subscriber will not see a `pane_hide`/`pane_show` event for
either of those two (mirroring `pane close`'s own lack of one, deferred to
`#0145` so as not to collide with its in-progress work on the event
vocabulary) — a hidden Pane is invisible to `watch` regardless of how it
got hidden. `session close` does still produce the pre-existing
`session_destroyed` event, but **only because this verb calls
`AppStateStore.removeSession(id:)`** — the sole emitter of that event. The
sidebar's own "Close" control is a *different* call site
(`WindowRuntime.removeSession(id:)`, called directly) and emits nothing at
all, so a Session a human closes from the sidebar is invisible to `batty
watch` today. Don't assume `session_destroyed` fires for every Session
removal — only for one reached through this CLI verb.

**Deliberately out of scope** (#0257's "a filed ticket reads as scheduled
work" rule): `tab new`, `tab close`, `session rename`, `tab rename`, and
`pane zoom` have no CLI verb yet. Do not invent them from
`batty-cli-design.md`'s forward-looking catalog.

## Failure handling

| Exit | Meaning | Agent response |
|---|---|---|
| `0` | Success | Continue. Capture stdout when the command returns an ID. |
| `1` | Local validation/general failure | Correct the path, UUID, view kind, or option combination. |
| `2` | Broker unreachable | Stop and ask the user to enable/reinstall the broker Login Item. |
| `3` | App unavailable | Retry once; then report that Batty could not launch or register. |
| `4` | App rejected the request | Report stderr; refresh topology before retrying a stale target. |
| `5` | App terminated during the request | Stop or restart the complete workflow from a fresh topology snapshot. |
| `6` | App is running but hasn't responded to the broker within the poll bound | Do not retry blindly — a retry cannot launch a duplicate, but the app may need a manual relaunch. Report stderr and ask the user to check/relaunch Batty. |
| `7` | Couldn't determine which on-disk app bundle to target | Stop; this is a local install problem (moved/missing `Batty.app`, or multiple bundles claiming the same identifier), not something a retry fixes. Report stderr, which names the expected path and any other claimant bundles. |
| `64` | Invalid CLI syntax | Correct the invocation; do not retry unchanged. |

**`batty new`'s exit `4` is an exception to the "retry a stale target" advice
above:** it means the poll timed out waiting to see the new Session, not that
the app rejected the request — retrying re-dispatches `batty new` and creates
a second Session. Refresh topology and look for the one that was (very
likely) already created instead.

Never parse human-readable `list sessions`, `list panes`, or `list tabs`
output in automation. Use `list --json`; the plain-text forms are for people.

## Current limitations relevant to agents

- There is no command that creates a Session and its Pane layout atomically.
  If a later split fails, the earlier Session and Panes remain.
- Batty currently exposes no CLI verbs for sending terminal input, reading
  screen contents, waiting for process state, creating a Tab, closing one
  Tab, renaming a Session/Tab, or zooming a Pane. Do not invent commands from
  the forward-looking catalog in `batty-cli-design.md`.
- `pane close` closes every Tab in the Pane and may refuse when confirmation is
  required or the Pane is the last one in the app. `session close` (`#0382`)
  has the same confirmation/last-remaining refusal one tier up, applied to
  Sessions instead of Panes — see "Cleaning up what you created" above.
- Since `#0379`, each Pane object in `list --json` / `session info --json`
  carries a `kind` field (`terminal`, `git-status`, `process-status`,
  `lm-studio-dashboard`, or `system-metrics`) — an agent can `jq
  'select(.kind == "git-status")'` to skip non-terminal Panes, for example.
  It renders as the string `"unknown"` in the plain-text forms; in `--json`
  output the `kind` key is simply absent from that Pane's object (the CLI
  decodes a `nil` and its `JSONEncoder` omits absent optionals rather than
  writing `null`). This is the case whenever the answering app predates
  `#0379` — which includes every currently installed build as of this
  writing. Treat an unrecognized or missing `kind` as "assume nothing about
  this Pane's content," not as an error.
