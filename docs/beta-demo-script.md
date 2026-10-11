# Beta demo script: driving Batty Beta from the `batty-beta` CLI

A live walk-through of the CLI remote-control surface on your own Mac. Every
command uses `batty-beta`, which talks only to Batty Beta (`co.sstools.Batty.beta`).
Prod (`/Applications/Batty.app`, `batty`) is never touched; don't run bare `batty`.

**How much of this has been run.** Each step below is covered by the Tart-VM UI
suite from #0413 (`CLIRemoteControlTests` + `CLIViewPaneTests`, 29/29 passing in
run `20261009-154250-31272`), which drives the real embedded CLI against a
launched Batty Beta and asserts the on-screen result. Steps or details that are
on #0413's **Not covered** list (tracked in #0447) are marked
**[not covered by the VM suite]**: watch those more closely, they have never been
checked by a test. The suite runs the CLI through a relay without `BATTY_*`
environment, so it passes explicit ids everywhere. §6 and §7 are the places
where this script leans on environment or focus fallbacks instead.

Requirements: `jq` (`brew install jq`), a Developer signing identity in your
login keychain (for `--sign`), macOS 15.6+.

## 0. Build, install, approve the broker

```sh
cd ~/Developer/brennanMKE/Batty
./build.sh package --sign
```

**`--sign` is required, once per install.** An unsigned Beta package cannot
register its XPC broker: `SMAppService` rejects it with `Codesigning failure
loading plist: co.sstools.Batty.beta.broker.plist code: -67056`, and every
`batty-beta` command except `capabilities` then exits 2 (`broker unreachable`)
(#0401). Repeated signed local builds are what revoked the signing certificate
once before, so sign **once per install, not once per code change**. If you
already have a working signed install, skip this step and do not rebuild just
to demo.

The app lands at `beta-build/Products/Batty Beta.app`. Copy it into place (the
script does not do this for you):

```sh
cp -R "beta-build/Products/Batty Beta.app" "/Applications/Batty Beta.app"
open "/Applications/Batty Beta.app"
```

Then, in Batty Beta:

1. **Settings → Advanced → Command-Line Tool → Install.** This symlinks
   `/usr/local/bin/batty-beta` to the CLI inside the app bundle (it asks for an
   administrator password).
2. **Settings → Advanced → Broker Agent → Register.**
3. Approve it if macOS asks: System Settings → General → Login Items &
   Extensions → Allow in the Background → **Batty Beta**.

Check:

```sh
command -v batty-beta
batty-beta --version
batty-beta ping      # batty: broker reachable
batty-beta status    # batty: pid … uptime …s windows … sessions … tabs … path=… version=…
```

If `ping` exits 2, the broker is not registered or not approved. Stop and fix
that: nothing downstream works without it. (`status` going through proves the
full broker → app-endpoint path, which `ping` alone does not.)

Window restoration is off (#0444), so Batty Beta always opens one fresh window
with one Session at `$HOME` on launch. That's expected, not a missed restore.

## 1. The CLI describes itself

```sh
batty-beta capabilities            # human-readable verb roster, exit codes, skill-install command
batty-beta capabilities --json | jq -r '.verbs[].name'
batty-beta capabilities --json | jq '.verbs[] | select(.name == "pane split") | .inputSchema.properties | keys'
```

Works even with Batty quit (it is compiled-in static data, no broker). Verbs:
`new`, `ping`, `status`, `list`, `session info|focus|close`,
`pane split|close|focus|hide|show`, `tab focus`, `id`/`whoami`, `notify`,
`capabilities`. This is what an agent reads instead of guessing.

## 2. Create a Session and capture its ids

`new` prints the Session id on line 1 and the focused Pane id on line 2 (#0380).

```sh
batty-beta new ~/Developer/brennanMKE/Batty
# <session-uuid>
# <pane-uuid>

NEW=$(batty-beta new --json ~/Developer/brennanMKE/Batty)
echo "$NEW"       # {"sessionID": "…", "paneID": "…"}
SID=$(echo "$NEW" | jq -r .sessionID)
PANE=$(echo "$NEW" | jq -r .paneID)
echo "session=$SID pane=$PANE"
```

The new Session is selected in the sidebar. (`--json` and `--no-wait` are
mutually exclusive; `--no-wait` dispatches and returns nothing.)

Don't `batty-beta new ~` from a cold start (Batty not running) as part of the
demo: a cold launch also creates its own default Session at `$HOME`, and the
id returned can be that one (#0380, accepted residual). With Batty already
running, as here, this doesn't arise.

## 3. Agent-shaped layout: terminal splits, then the status views

Always pass `--pane` explicitly and chain by the id each split returns. Never
assume focus followed a split. `pane split` prints the new Pane id and nothing
else on stdout. `-h`/`--horizontal` (default) splits left/right, `-v`/`--vertical`
splits top/bottom.

```sh
# terminal Panes running commands (the Pane stays open after the command exits)
LOG=$(batty-beta pane split -h --pane "$PANE" --command "git log --oneline -20")
echo "log pane: $LOG"
TESTS=$(batty-beta pane split -v --pane "$LOG" --command "ls -la")
echo "second pane: $TESTS"
```

### The headline: `--unique` is idempotent

```sh
GIT=$(batty-beta pane split --pane "$PANE" --view git-status --unique)
GIT2=$(batty-beta pane split --pane "$PANE" --view git-status --unique)
echo "$GIT"; echo "$GIT2"
[ "$GIT" = "$GIT2" ] && echo "same Pane id: idempotent" || echo "DUPLICATE CREATED"
```

The second call prints the same id on stdout and
`--unique matched an existing pane; nothing created` on stderr. A setup script an
agent re-runs does not stack duplicate dashboards. Rules worth knowing:
it matches only a **visible** Pane of that kind within the **target Session**,
and a different `--path`/`--pid` does not defeat the match. **[not covered by the
VM suite: the hidden-Pane-is-not-a-match rule, and that a match never moves
focus. Try `pane hide "$GIT"` then rerun the `--unique` line in §5 and expect a
new id.]**

### The other view kinds

```sh
PROC=$(batty-beta pane split --pane "$PANE" --view process-status --pid $$)
METRICS=$(batty-beta pane split --pane "$PANE" --view system-metrics)
LMS=$(batty-beta pane split --pane "$PANE" --view lm-studio-dashboard)
```

- `git-status` takes `--path <dir>` (defaults to the target Pane's working
  directory); `--path` is rejected for any other kind.
- `process-status` takes `--pid <n>` to pin it to a process (here your shell);
  without it, it follows the source Pane's foreground process. **[not covered by
  the VM suite: the VM test checks the view appears and that `--pid` is
  accepted, not the pinned process's run-state chip or banners.]**
- `lm-studio-dashboard` shows a not-connected state unless LM Studio's server
  is running; that is fine for the demo.
- `--command` is rejected with any non-terminal `--view` (no shell there), and
  `--unique` is rejected without one. Both exit 1.

Look at the window: each view should render in its own Pane, and the source
terminal should shrink to make room rather than a terminal filling the whole
window (the #0333 symptom; the VM suite asserts this per kind).

## 4. Read the topology: `list --json | jq`

Plain-text `list` is for people; scripts use `--json`, which always returns the
full topology (`windows[].sessions[].root`, a tree of `leaf`/`split` nodes).

```sh
batty-beta list --json | jq -r '
  .windows[].sessions[] | .id as $s | .name as $n | .root | .. | .leaf? // empty
  | .pane | [$n, .id, .kind, (.isHidden|tostring)] | @tsv'
```

Expect one row per Pane with `kind` in `terminal`, `git-status`,
`process-status`, `system-metrics`, `lm-studio-dashboard`. A missing `kind`
means the answering app predates the field; treat it as "unknown".

Other readers: `batty-beta list` (Sessions), `batty-beta list panes`,
`batty-beta list tabs`, `batty-beta session info --session "$SID"`. **[`list
sessions|tabs`, `session info` without `--session`, and `list --include-dimensions`
are not covered by the VM suite; `list` and `session info --session` are.]**

## 5. Focus, hide, show, close, and `session close`

```sh
batty-beta pane focus "$GIT"          # raises the window and focuses that Pane
batty-beta pane hide --pane "$GIT"    # out of view, still alive
batty-beta list --json | jq '[.. | .isHidden? | select(. == true)] | length'   # 1
batty-beta pane show "$GIT"           # explicit id is required for show
batty-beta tab focus "$(batty-beta list --json | jq -r '[.. | .tabs? // empty | .[].id][0]')"
```

- `pane show` is the one verb with no env/focus fallback (a hidden Pane has no
  shell to run from).
- `pane hide` and `pane show` are idempotent. `pane hide` exits 4 when the
  target is the Session's only visible Pane.
- `pane focus` and `tab focus` take an id; directional and indexed forms do not
  exist. **[not covered by the VM suite: focusing a Pane or Tab in a
  non-selected Session, and that focus brings the window forward when Batty Beta
  is in the background. Try the latter: click another app, then run `pane focus`
  from a different terminal app and see whether Batty Beta comes to the front.]**

Clean up what the script made:

```sh
batty-beta pane close --pane "$METRICS"
batty-beta pane close --pane "$PROC"
batty-beta pane close --pane "$LMS"
batty-beta pane close --pane "$TESTS"
batty-beta pane close --pane "$LOG"
batty-beta session close --session "$SID"
```

`pane close` ends every Tab in the Pane. Both `pane close` and `session close`
exit 4 rather than closing the app's last Pane or last Session, or a Tab that
needs close-confirmation; there is no `--force`. (If a Pane still runs a
foreground process, the confirmation dialogs never fire in a running app today
(#0398), so expect silent closes.)

## 6. `notify`

```sh
batty-beta notify --title "Build finished" --body "3 warnings"
```

Opens an entry in the Bell Feed (toolbar button) and posts the macOS
notification, subject to your Settings → Notifications and Focus mode.
`--sound` is subject to the "Play sound" setting. With no `--tab`, it attributes
to the focused Tab; `--tab` takes a **Tab** id (from `list --json`), not a Pane
id. A Pane id there exits 4.

**[not covered by the VM suite: `--sound`, the entry's title/body text, which
Tab the entry is attributed to, notifying while a different Session is in the
background, and `notify` with no `--tab` (the focused-Tab fallback). The VM test
only checks that entries appear in the Bell Feed and that an unknown `--tab` is
refused. Check the rest by eye.]**

## 7. Inside a Batty Pane: an agent's real situation

Everything above ran from an arbitrary terminal. An agent runs *inside* a Batty
Pane, where Batty injects `BATTY_SESSION_ID`, `BATTY_PANE_ID`, `BATTY_TAB_ID`,
so ids and targets resolve without being passed. Open a new Session and do this
**in its terminal**, not in the terminal you've been scripting from:

```sh
batty-beta new ~/Developer/brennanMKE/Batty    # run from your outside terminal; focus moves to the new Session
```

Then, in that Session's Pane:

```sh
env | grep '^BATTY_'
batty-beta id             # session/pane/tab ids; no app connection
batty-beta id --json

# target resolution is flag -> BATTY_* env -> focused element
batty-beta pane split --view git-status --unique    # splits THIS Pane
batty-beta pane split --view git-status --unique    # same id again, stderr note
right=$(batty-beta pane split -h --command "tail -f /dev/null")
batty-beta pane split -v --pane "$right" --command "echo chained by id"
batty-beta notify --title "Agent: layout ready"
batty-beta pane focus "$right"
```

Chain later splits with `--pane <id from the previous split>`, not the
inherited env: `BATTY_PANE_ID` keeps pointing at the Pane the agent started
in, and focus can move at any moment. `batty-beta id` run from a terminal
outside Batty exits non-zero (no `BATTY_*` context).

The VM suite covers `--unique` twice from inside a Pane with its `BATTY_*`
environment, and `id` inside and outside a Pane. **[not covered by the VM suite:
`pane split` with no `--pane` and `notify` with no `--tab` relying on the
focused-element fallback; the `BATTY_*` env path is what you're exercising
here.]**

Clean up in the same Pane: `batty-beta session close` (falls back to
`BATTY_SESSION_ID`). It closes the Pane you're typing in, so run it last.

## 8. Install the agent skill

The skill teaches an agent the *sequencing* that the schema can't: which id to
keep, what each exit code means to do next, why `--unique`, why not to re-run
`new` after exit 4.

```sh
batty-beta capabilities
```

The tail of the output (`agent skill:`) prints an install command pre-filled
with this build's own version: a shallow clone of tag `v<cliVersion>` from
`github.com/brennanMKE/Batty`, then `.claude/skills/batty-cli/install.sh`, which
installs for every agent host it detects (Claude Code, Cursor, OpenCode, Codex).
Paste that block, or preview first by adding `--dry-run` to the `install.sh`
line. It is non-destructive: a failed clone or a tag that predates the
installer leaves existing copies alone. The installer needs the tag to exist on
the remote; if the clone fails, the tag for this build hasn't been pushed (or you
are offline), and you can run `.claude/skills/batty-cli/install.sh` straight
from this checkout instead.

Then, in a fresh agent session inside a Batty Pane, ask it to "open a git-status
view and a test-watcher split in this Session and tell me when it's ready" and
watch it bootstrap with `capabilities --json`, `id`, `pane split --unique`,
`notify`. The skill file is `.claude/skills/batty-cli/SKILL.md`; the fuller
reference is `docs/batty-cli-agent-workflows.md`.

## Failure vocabulary (what you may hit live)

| Exit | Meaning |
|---|---|
| 1 | Bad path, id, or flag combination (client-side) |
| 2 | Broker unreachable: not registered, not approved, or (unsigned build) rejected |
| 3 | App unavailable |
| 4 | App refused: stale id, only visible Pane, last Pane or Session, or `new` poll timeout (do not re-run `new`; look in `list --json`) |
| 5 / 6 / 7 | App died mid-request / running but unregistered / can't pick one app bundle |
| 64 | Invalid syntax (also an unknown `--view` kind) |

## Known issues you may notice during the demo

- **Colours over SSH (#0399).** `ssh` to another host will not get `COLORTERM`
  or a resolvable `TERM` from Batty today: the pinned libghostty ships no `ssh()`
  wrapper, so a remote `vim`/`htop` may render wrong or monochrome. Unrelated to
  the CLI; don't demo SSH.
- **No shell integration for fish, elvish, or nushell (#0400).** Only bash and
  zsh get cwd tracking and prompt marks. In another shell, tab and Session
  titles may not follow `cd`, and anything reading a Pane's working directory
  (for example `git-status` with no `--path`) may fall back to where the Pane
  started. Use `--path` explicitly, or demo from zsh/bash.
- **Close confirmations don't fire (#0398).** Closing a Pane with a running
  process closes silently.
