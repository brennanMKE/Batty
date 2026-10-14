---
name: batty-cli
description: Drive the Batty macOS terminal multiplexer from its `batty`/`batty-beta` command-line tool — creating Sessions, splitting terminal or status-view Panes (git-status, process-status, system-metrics, lm-studio-dashboard), notifying or focusing the human, and cleaning up afterward. Use whenever a task calls `batty`, mentions Batty Sessions/Panes/Tabs from the CLI, or needs to script Batty from an agent running inside one of its Panes or from an unrelated project.
---

# Batty CLI

**Authored against Batty CLI `1.1.0`.** Minimum compatible app version: `1.1.0`
(see "Version check" below for what that pin does and doesn't mean). The two
values are identical today because this is the skill's first version —
that clause can't yet distinguish anything from the plain version-equality
check. It exists for a *future* skill update that adds a recipe depending on
a flag not yet universal at the time it's authored, so the minimum can trail
the authored-against version independently once that happens.

This skill teaches the **sequencing** knowledge a machine-readable schema
can't carry: what order to call things in, which id to keep, and what a
given exit code actually means to do next. It never restates *what
parameters exist* — every verb's parameters, enum values, defaults, and
cross-flag conflicts live in `batty capabilities --json`'s `verbs[].inputSchema`,
and that live output always outranks this file's prose when the two disagree.
Read it first, every session, before calling any other verb.

## 1. Bootstrap (run once per session, before anything else)

There are **three** artifacts that can skew, not two: this skill, the
`batty`/`batty-beta` binary you're invoking, and the **app instance that
actually answers XPC requests** — normally the same version as the binary
(the installed CLI is a symlink into the app bundle), but not guaranteed:
a stale running instance, or a machine with both Prod and Beta installed,
can leave the CLI binary and the answering app at different versions.
`capabilities --json`'s `inputSchema` describes only the **CLI binary's own
compiled-in surface** — it is not proof the answering app actually honors a
given flag. So the bootstrap checks both:

```sh
BATTY=$(command -v batty || command -v batty-beta)   # Prod installs `batty`, Beta installs `batty-beta`; a dev machine can have both
"$BATTY" ping                                         # broker reachable?
"$BATTY" capabilities --json                          # this CLI binary's own surface — capture .cliVersion
"$BATTY" status --json                                # the answering app — capture .status.appVersion (may fail; see below)
```

Every recipe below assumes `$BATTY` was resolved this way — use `"$BATTY"`,
not a hardcoded `batty`, or every recipe silently becomes
command-not-found on a Beta-only machine.

Compare **both** `cliVersion` (top-level on `capabilities --json`) and
`.status.appVersion` (nested under `status --json`'s `status` object — not
top-level, unlike `cliVersion`) against `1.1.0` above. From here on
"`appVersion`" means that nested field. `appVersion` is the one that matters
for "will the app actually do this," `cliVersion` is the one that matters
for "does this binary know how to ask":

| Captured version | Meaning | What to do |
|---|---|---|
| `cliVersion == "unknown"` | Bare SwiftPM-built binary, not an app-bundle install — **not a mismatch**, just unverifiable. | Tell the human once. For the rest of the session, treat live `inputSchema` as the only authority for what the CLI can *send*; it says nothing about whether the app *honors* it. |
| `status --json` fails (any non-`0` exit — `2`/`3`/`4`/`5`/`6`/`7`) | The JSON still parses, but its `status` key is omitted entirely on failure — no app answered, so there's no `appVersion` to check. | Tell the human once that only `cliVersion` could be verified. Retry `status` before trusting the dangerous-direction check below. |
| Both equal `1.1.0` | Authored-against version matches on both axes. | Proceed. The schema is still the call-time authority regardless — a version match answers "is this skill stale," not "what can this build do." |
| `cliVersion` and `appVersion` disagree with each other | The binary you're running and the app answering it are different builds (stale instance, or Prod+Beta both installed and you're mid-verb-typo). | Tell the human once; treat the **older** of the two as governing for the dangerous-direction check below — the older side is where a flag can silently be ignored. |
| Either is newer than `1.1.0` (skill older) | Benign. This skill may be missing newer verbs/flags. | Tell the human once, then proceed — anything new shows up in `inputSchema` even though this skill doesn't mention it. |
| Either is older than `1.1.0` (skill newer) | **The dangerous direction** — this skill may teach a flag the *answering app* silently ignores (`--unique` against a pre-flag app is the concrete precedent: it creates a duplicate Pane instead of erroring). Checking `inputSchema.properties` on the CLI binary is **not sufficient** here if it's `appVersion` that's behind — the binary can advertise a flag the app it's talking to doesn't implement. | Tell the human once. If `cliVersion` is the one behind, confirm the parameter appears in live `inputSchema.properties` before using it. If `appVersion` is the one behind (or unconfirmed because `status` failed), there is no live schema for the *app's* surface — treat every recipe below as unverified and prefer the human's confirmation over any automated check. |

**Never hard-fail on a mismatch in either direction.** A version skew is a
reason to double-check, not a reason to refuse to work — the schema-authority
rule above is what makes every direction recoverable, though it only covers
the CLI-binary axis, not the answering-app axis (see the table). Run this
comparison exactly once, at the same moment as the bootstrap
`capabilities --json`/`status --json` calls above; don't repeat it before
every subsequent `batty` call, and don't try to run it at "skill load" —
loading this file is inert, nothing has executed yet.

If `batty capabilities` itself isn't a recognized verb (pre-#0384 CLI: it
silently falls through to `batty new capabilities`, i.e. tries to create a
Session at a path literally named `capabilities` and fails), treat the
installed CLI as predating this entire skill. Fall back to `--help` on each
subcommand and verify everything by hand.

**Refreshing this skill**, from the exact tagged release the installed app
shipped from (only if the human asks, or you hit the dangerous direction
above and want the matching copy). Every tagged copy of this skill folder
carries its own installer, `install.sh`, next to this file — running it
detects and updates **every** agent host present (Claude Code, Cursor,
OpenCode, Codex), not just whichever host this particular copy happens to
live in (#0404: a copy living in, say, OpenCode's skills directory must not
follow instructions that refresh only Claude's — that leaves it stale, the
exact #0383 skew self-inflicted). Non-destructive: a clone failure (network,
or a tag that doesn't exist) or a tag that predates the installer entirely
(any tag before #0404) is reported and left alone, and `install.sh` itself
applies the same stage-to-`.new`/verify-`SKILL.md`/swap discipline
per-destination that this recipe used to do inline for one hardcoded path
(see the script's own header comment). It never fabricates a tag from
`"unknown"` either:

```sh
tmp=$(mktemp -d)
if [ "$CLI_VERSION" = "unknown" ]; then
  echo "cliVersion is \"unknown\" — not a real tag; find the matching release manually:" >&2
  echo "  https://github.com/brennanMKE/Batty.git (tags)" >&2
elif ! git clone --quiet --depth 1 --branch "v$CLI_VERSION" https://github.com/brennanMKE/Batty.git "$tmp"; then
  echo "clone of v$CLI_VERSION failed (network error, or the tag doesn't exist) — existing copy left untouched" >&2
elif [ ! -x "$tmp/.claude/skills/batty-cli/install.sh" ]; then
  echo "tag v$CLI_VERSION has no agent-skill installer (added in #0404) — existing copy left untouched" >&2
else
  "$tmp/.claude/skills/batty-cli/install.sh"   # add --project DIR and/or --dry-run as needed
fi
rm -rf "$tmp"
```

(`$CLI_VERSION` is the `cliVersion` captured above. `batty capabilities`'s
plain-text output prints the equivalent command pre-filled — see
`docs/batty-cli-agent-workflows.md` and #0403 for why it doesn't appear in
`--json`. Run `install.sh --help` for the full flag list, or read its header
comment for which host lands in which directory and why.)

## 2. Finding ids

```sh
"$BATTY" id --json          # BATTY_SESSION_ID / BATTY_PANE_ID / BATTY_TAB_ID inherited from this Pane, if any
"$BATTY" list --json        # full live topology — the only form to parse; never parse plain-text `list`
```

Target resolution order for any flag-driven command: explicit
`--session`/`--pane`/`--tab` flag, then the matching `BATTY_*` env var, then
whatever Batty currently has focused. **Prefer explicit ids.** An inherited
`BATTY_*` env var keeps pointing at the Pane the agent started in even after
it creates a new Session; focus is user-controlled and can move at any time.

## 3. Capture ids as you create things — there is no `outputSchema` for this

`pane split` prints the new Pane's id on stdout; `batty new` prints the new
Session id on line 1 and its focused Pane id on line 2 (or
`{"sessionID":…,"paneID":…}` with `--json`). **Neither is discoverable from
the JSON schema** — `inputSchema` describes call parameters, not what a verb
prints back. Capture it and chain by that id; never chain by assuming focus
followed the split.

```sh
pane_id=$("$BATTY" pane split --horizontal --command "npm run dev") || exit $?
"$BATTY" pane split --horizontal --pane "$pane_id" --command "npm test -- --watch"
```

`batty new`'s exit codes need special handling — its poll can time out
without the request having been rejected:

| Exit | What actually happened | What to do |
|---|---|---|
| `0`, no stdout | Degraded path: couldn't snapshot topology before dispatch, so the Session *was* still created but its id can't be reported. | Don't treat empty stdout as failure; find the Session with `batty list --json`. |
| `4` | Poll timed out — this is **not** a rejection. `list` kept succeeding the whole time. | **Do not re-run `batty new`** — it creates a duplicate Session. Refresh `batty list --json` and look for it by path. This is the one place a `4` doesn't mean "app rejected it." |
| `3` (or `2`) | Cold-launch poll never saw an endpoint at all — no evidence the Session was created. | `batty ping`/`batty status` before retrying. |
| Other | See the exit-code table below. | — |

A cold `batty new ~` (Batty not yet running, target is `$HOME`) can also
produce two Sessions at once — the launch's own default Session plus the
requested one — and if that ambiguity never resolves to exactly one match,
`batty new` reports it as the `4` case above rather than guessing. Don't
assume a `4` here means nothing happened.

## 4. `--unique`: the idempotency flag for setup scripts

Any `pane split` without `--unique` creates a new Pane every time it runs —
fine for a one-shot action, wrong for a setup step that might re-run (retry,
restart, or just habit):

```sh
git_pane=$("$BATTY" pane split --view git-status --unique) || exit $?
```

Safe to run any number of times: the first call creates the Pane; every
later call finds the same **visible** Pane of that kind already in the
target Session and returns its id, creating nothing new. Two asymmetries to
know: it matches only within the current Session, and only a *visible* Pane
(a hidden one doesn't count — see §6); and an ordinary split moves focus to
the new Pane only if the target was already focused, while a `--unique`
*match* never moves focus — so a script's first run may steal focus and its
second run won't. Chaining by `--pane`/env is unaffected either way.

## 5. `notify` tells, `focus` shows

`batty notify --title … [--tab <tab-id>]` posts to the Bell Feed and hopes
the human notices it later. `batty {session,pane,tab} focus <id>` brings
that element and Batty's window in front of the human **immediately** — the
CLI's one sanctioned exception to "don't steal focus for a background
target." Use `notify` for something the human can check on their own time;
use `focus` when they need to see it now.

**`--tab` takes a Tab id, not a Pane id** — `pane split`'s returned id is a
Pane id, and passing it to `--tab` resolves to `.unknownTab` and exits `4`.
Omit `--tab` to fall back to `BATTY_TAB_ID`, then the focused Tab, which is
what a script holding only a Pane id from a split actually wants; pass a
real Tab id (from `list --json`) only if attributing to a Tab other than the
current one.

```sh
new_pane=$("$BATTY" pane split --horizontal --command "npm run dev")
"$BATTY" notify --title "Dev server starting"
# ... later, once it needs attention ...
"$BATTY" pane focus "$new_pane"
```

## 6. Cleaning up: `pane hide`/`pane show`, `session close`

`pane hide`/`pane show` are idempotent (hide-when-hidden and
show-when-visible both succeed quietly). **`pane show` is the one verb with
no fallback target** — it requires an explicit `<pane-id>` and never falls
back to `BATTY_PANE_ID` or the focused element, because a hidden Pane has no
shell a `batty` call could be running from. Get hidden ids from
`batty list --json`, which flags them `"hidden": true`.

`pane hide` itself also refuses (exit `4`) when the target is its Session's
only **visible** Pane — a Session must always show at least one, so there's
nothing left to hide it behind. When §7's exit-`4` row below says "refresh
topology before retrying," that generic advice won't fix *this* cause:
refreshing topology just confirms the same one visible Pane is still there.
Split or show another Pane in that Session first if you actually need this
one hidden.

`session close` can refuse (exit `4`) rather than silently doing something
surprising: an unconfirmed Tab close, or closing Batty's last remaining
Session. Check `batty list --json` before retrying a refusal instead of
looping.

## 7. Exit codes: recovery, not just meaning

`capabilities --json`'s `exitCodes` array names every code; this is what to
actually *do* about each one — the part a schema can't encode:

| Exit | Recovery |
|---|---|
| `0` | Continue; capture stdout if the verb returns an id. |
| `1` | Client-side problem (bad path/id/option combo) — fix the invocation, don't retry unchanged. |
| `2` | Broker unreachable — stop, ask the human to check the broker Login Item. |
| `3` | App unavailable — retry once, then report it couldn't launch/register. |
| `4` | App rejected the request (**except `batty new`, see §3**) — refresh topology before retrying a stale target. |
| `5` | App terminated mid-request — restart the whole workflow from a fresh topology snapshot. |
| `6` | App running but unregistered with the broker — don't retry blindly; ask the human to check/relaunch. |
| `7` | Can't determine which on-disk app bundle to target — stop, this is a local install problem, not something a retry fixes. |
| `8` | `project open` only: the startup-command prompt in Batty went unanswered; nothing opened. Ask the human to answer it, then retry. |
| `64` | Invalid syntax — fix the invocation. |

## 8. Opening a saved Project

`project list` and `project open <name>` exist in both `batty` and
`batty-beta` from 1.3.0. An older install has no `project` noun, so check
`capabilities --json` before using them: if `project open` is not in `verbs`,
the build does not have the feature, and you should not try another spelling.

```bash
"$BATTY" project list --json
"$BATTY" project open "My Project" --json   # sessionID, paneID, created, name
```

`open` focuses the Project's Session when one is already open
(`created: false`); `--new` opens another copy. An unknown name exits `4` and
lists close matches. **You cannot skip the startup-command approval prompt:**
if the Project's commands are new or changed, Batty asks the human and the
command waits for their answer (up to 120 seconds). Exit `8` means nobody
answered and nothing was opened; ask the human to be at Batty, then run it
again. Do not try to work around the prompt.

## What this skill deliberately does not cover

Parameter names, types, enum values (the five `PaneContentKind`s, split
`direction`), defaults, and the cross-flag conflicts — `pane split`'s four
(`--unique`/`--command`/`--pid`/`--path`, each keyed off `--view`) plus
`new`'s `--json`/`--no-wait` exclusion — all live in
`batty capabilities --json`'s per-verb `inputSchema` (#0402) — call it and
read that instead of guessing from this file or from `--help` text. This
division is deliberate: the schema churns with every flag; the sequencing
knowledge above has been stable across
several issues (#0380–#0383) and is what actually breaks a naive script
when missed.

## Relationship to `docs/batty-cli-agent-workflows.md`

That doc is the fuller, canonical reference — installation prerequisites,
the complete `batty new`/URL trace, every corner case, and the exact stderr
wording for each failure. This skill is a **condensed subset** of its
sequencing sections for a reader with no repo access, not a superset or a
replacement: the doc stays canonical, issue files keep citing its section
names, and this file exists to reach an agent that will never see the repo.
If this file and the doc ever disagree, the doc wins — file that as a Batty
issue; a same-repo commit updating one should update the other in the same
diff, since there's no mechanical drift check across two prose files (see
`issues/0403.md`'s Notes for what a release-time hook covering this would
look like).
