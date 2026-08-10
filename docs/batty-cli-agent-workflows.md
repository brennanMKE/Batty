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

`batty new <path>` uses a one-way macOS URL event. It exits after Launch
Services accepts the URL, before the CLI can know that Batty created the
Session. It also prints no Session or Pane ID. Therefore an agent must not
assume that an immediately following unqualified `batty pane split` targets
the new Session.

Save the following zsh script as `batty-project-layout` and make it executable.
It handles that boundary deterministically:

```sh
#!/bin/zsh
set -u

if [ "$#" -lt 1 ]; then
    echo "usage: batty-project-layout <project-directory> [command ...]" >&2
    exit 64
fi

project_dir=$(cd "$1" 2>/dev/null && pwd -P) || {
    echo "project directory does not exist: $1" >&2
    exit 1
}
shift

before_json=$(mktemp -t batty-before.XXXXXX) || exit 1
cleanup() { rm -f -- "$before_json" }
trap cleanup EXIT HUP INT TERM

batty list --json >"$before_json" || exit $?
batty new "$project_dir" || exit $?

pane_id=
attempts=0
while [ "$attempts" -lt 50 ]; do
    topology=$(batty list --json) || exit $?
    pane_id=$(printf '%s\n' "$topology" | jq -r \
        --arg project "$project_dir" \
        --slurpfile before "$before_json" '
            [$before[0].windows[].sessions[].id] as $old_ids
            | first(
                .windows[].sessions[]
                | . as $session
                | select(.path == $project)
                | select(($old_ids | index($session.id)) == null)
                | .focusedPaneID
            ) // empty
        ')

    [ -n "$pane_id" ] && [ "$pane_id" != "null" ] && break
    attempts=$((attempts + 1))
    sleep 0.1
done

if [ -z "$pane_id" ] || [ "$pane_id" = "null" ]; then
    echo "Batty did not report the new project Session within 5 seconds" >&2
    exit 3
fi

for command in "$@"; do
    pane_id=$(batty pane split --horizontal --pane "$pane_id" \
        --command "$command") || exit $?
done
```

Example:

```sh
batty-project-layout "$HOME/Developer/MyApp" \
    "npm run dev" \
    "npm test -- --watch"
```

How it works:

1. Canonicalizes and validates the project directory.
2. Saves the existing Session IDs from `batty list --json`.
3. Requests a new Session at the project path.
4. Polls topology until a new Session with that path appears.
5. Reads that Session's `focusedPaneID` and passes it explicitly to the first
   split.
6. Uses each successful `pane split` result as the next target, so subsequent
   Panes extend to the right in command order.

`--horizontal` creates a left/right split and the returned ID belongs to the
new right-hand Pane. `--command` replaces the configured shell for that Pane
and keeps the Pane open after the command exits so its output remains visible.

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
because the inherited environment still identifies the old Pane.

## Failure handling

| Exit | Meaning | Agent response |
|---|---|---|
| `0` | Success | Continue. Capture stdout when the command returns an ID. |
| `1` | Local validation/general failure | Correct the path, UUID, view kind, or option combination. |
| `2` | Broker unreachable | Stop and ask the user to enable/reinstall the broker Login Item. |
| `3` | App unavailable | Retry once; then report that Batty could not launch or register. |
| `4` | App rejected the request | Report stderr; refresh topology before retrying a stale target. |
| `5` | App terminated during the request | Stop or restart the complete workflow from a fresh topology snapshot. |
| `64` | Invalid CLI syntax | Correct the invocation; do not retry unchanged. |

Never parse human-readable `list sessions`, `list panes`, or `list tabs`
output in automation. Use `list --json`; the plain-text forms are for people.

## Current limitations relevant to agents

- `new` is the only shipped mutation without an app acknowledgement or returned
  object ID. Use the snapshot-and-poll pattern above.
- There is no command that creates a Session and its Pane layout atomically.
  If a later split fails, the earlier Session and Panes remain.
- Batty currently exposes no CLI verbs for sending terminal input, reading
  screen contents, waiting for process state, or closing one Tab. Do not invent
  commands from the forward-looking catalog in `batty-cli-design.md`.
- `pane close` closes every Tab in the Pane and may refuse when confirmation is
  required or the Pane is the last one in the app.
