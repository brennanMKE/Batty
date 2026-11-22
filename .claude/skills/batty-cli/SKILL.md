---
name: batty-cli
description: Drive the Batty macOS terminal multiplexer through its `batty`/`batty-beta` CLI or `batty mcp` server (Sessions, Panes, Tabs, status views, dev servers, Reminders, notify/focus, and cleanup); use whenever a task calls `batty` or scripts Batty from an agent.
---

# Batty CLI

**Requires Batty `1.5.0` or later** (`batty` in Batty, `batty-beta` in Batty Beta).
`batty agent install` installs the copy that ships with your Batty, so this skill matches the CLI, and `batty capabilities --json` outranks this file when they disagree.

## 1. Am I in Batty?

```sh
BATTY=$(command -v batty || command -v batty-beta)
"$BATTY" agent context        # Session/Tab/Pane ids and the rules; prints nothing outside Batty
```

Fallback: `env | grep '^BATTY'`. Resolve `$BATTY` once and use `"$BATTY"` everywhere.

## 2. Bootstrap

```sh
"$BATTY" agent context
"$BATTY" capabilities --json   # verbs[].inputSchema, exitCodes, cliVersion
"$BATTY" status --json         # .status.appVersion
```

`capabilities --json` is the only authority for verbs, parameters, defaults and conflicts.
If `cliVersion` is below 1.5.0, or `.status.appVersion` differs from `cliVersion`, tell the human once and use only what `inputSchema` lists.
Never hard-fail on a version mismatch. `cliVersion == "unknown"` means a SwiftPM-built binary.

## 3. When to use Batty

- Show status in Panes: `"$BATTY" pane split --view git-status --unique`.
- Start dev servers with `server start` (or `server share` one already running); preview static pages with `server serve`, never `python3 -m http.server`.
- Use `tab new` or `pane split --wait` when you need a command's exit status.
- `notify` tells the human; `focus` shows them now.
- Set `session remind` instead of polling.
- Save a setup for the user: `background list`, then `project create --layout-json`, then `project open` (commands still need their approval).
- Save the user's current Session: `project create --from-session`, with `--symbol-name` (any SF Symbol, exact name), `--color-hex` from the folder's accent color (AccentColor.colorset, CSS/Tailwind theme color, logo; omit if unclear) and a background from `background list` (a first image gets 30% opacity; use less for a dark image under a light Theme).

**Progressive disclosure:** use these when they help the user follow your work. Don't push Batty features the user didn't ask for.

## 4. Sequencing the schema can't carry

Capture ids from stdout and chain by id: `pane split` prints a Pane id; `new` prints the Session id, then the Pane id.

```sh
pane_id=$("$BATTY" pane split --horizontal --command "npm run dev") || exit $?
"$BATTY" pane split --horizontal --pane "$pane_id" --command "npm test -- --watch"
```

- Prefer explicit ids over `BATTY_*` variables and focus; both can point somewhere else by now.
- `--unique` makes setup re-runnable: `"$BATTY" pane split --view git-status --unique` returns the existing visible Pane of that kind. A first split may move focus; a `--unique` match never does.
- `"$BATTY" notify --title "Tests passed" --tab <tab-id>` takes a Tab id, not a Pane id. Omit `--tab` to use your own Tab.
- `pane show` needs an explicit Pane id (from `list --json`). `pane hide` refuses on a Session's only visible Pane.

## 5. Exit codes: what to do next

| Exit | Recovery |
|---|---|
| `0` | Continue; capture stdout. From `new` with no stdout: the Session exists, find it with `list --json`. |
| `1` | Client-side problem. Fix the invocation; don't retry unchanged. |
| `2` | Broker unreachable. Ask the human to check the broker Login Item. |
| `3` | App unavailable. Retry once, then report it. |
| `4` | App rejected the request; refresh `list --json` before retrying. From `new` it is a poll timeout: **don't re-run `new`**, look for the Session by path. |
| `5` | App terminated mid-request. Restart from a fresh `list --json`. |
| `6` | App running but unregistered. Ask the human to relaunch it. |
| `7` | Can't tell which app bundle to target. A local install problem; stop. |
| `8` | `project open` only: the startup-command prompt went unanswered. Ask the human, then retry. |
| `64` | Invalid syntax. Fix the invocation. |

## 6. Dev servers and looking at a page

```sh
"$BATTY" server start --port 8083 --wait --json -- go run .
"$BATTY" server serve ./dist --json
"$BATTY" server list --json
```

`server serve` uses PhotonHTTP's `photon` when it is installed, else Batty's built-in server; `--engine builtin|photon` picks one.

Batty has no web view or in-app browser. To look at or test a page, use the webdriver the developer has told you about (for example `safaridriver`, after they run `safaridriver --enable` once) against the URL from `"$BATTY" server list --json`.
Batty never launches a browser or a browser automation tool, and you don't open a browser yourself unless asked.
Share a server on the tailnet (`server tailnet`) only when the user asks.
Stop or unshare only the servers you started or shared.

## 7. Close what you open

```sh
"$BATTY" pane close --pane "$pane_id"
"$BATTY" server stop --port 8083
"$BATTY" session close --session "$session_id"
```

`session close` may refuse with exit `4`: check `list --json`, don't loop.

## 8. MCP

`batty mcp` serves the `capabilities` verbs minus `mcp`, `agent install` and `agent context`.
A tool's name is the verb path with `_` (`pane_split`); its parameters are `inputSchema` without `json`.
Errors start `exit <code>:` (see §5). Omitted targets resolve through `BATTY_*`.

## 9. Adding Batty to your global instructions

Batty never edits your global instructions file. When the user asks you to add Batty to it, do what this prompt says; Settings → Advanced → AI Agents → Copy Prompt gives the user the same text:

````text
Add Batty to your global instructions, the file you read at the start of every session:

- Claude Code: `~/.claude/CLAUDE.md`
- Codex: `~/.codex/AGENTS.md`
- OpenCode: `~/.config/opencode/AGENTS.md`
- Cursor has no such file: show me the section below so I can paste it into Cursor's User Rules (Cursor Settings → Rules).

If the file does not exist, create it. If it already has a `## Batty` section, replace that whole section, from its heading up to the next `## ` heading or the end of the file, with the text below; do not add a second one. Change nothing else in the file. Then tell me which file you changed.

```markdown
## Batty

At the start of a session, run `env | grep '^BATTY'`. If `BATTY_SESSION_ID`, `BATTY_TAB_ID` and `BATTY_PANE_ID` are set, you are running in a terminal Pane of Batty, a macOS terminal multiplexer, and can drive it:

- Prefer the `batty` MCP tools (`batty-beta` in Batty Beta) when they are available (`batty mcp`, installed by `batty agent install`). Otherwise use the CLI: `batty` (or `batty-beta` in Batty Beta). Run `batty capabilities` to see the available commands.
- Use Batty to split Panes and set reminders (`batty session remind`) when they help the user follow your work.
- Show status in Batty Panes (`batty pane split --view git-status --unique`) rather than printing it.
- Start dev servers with `batty server start --port N -- <command>` (or `batty server share --port N` if one is already running) when `batty capabilities` lists it. Don't open a browser yourself; pass `--split` only when the user asked for a placement.
- Preview static pages with `batty server serve <dir> --open`, never `python3 -m http.server`.
- Use `batty notify` to get the user's attention.
- Close the Panes and Sessions you open when you are done with them.

If those variables are not set, you are not in Batty; ignore this section.
```
````

## 10. Installing or refreshing this skill

```sh
"$BATTY" agent install --dry-run   # what would change
"$BATTY" agent install
```

Without the app, download https://batty.sstools.co/docs/skill/batty-cli-skill-latest.zip and unzip it into your agent host's skills folder.

Fuller reference: Help → AI Agents in Batty.
Online: https://batty.sstools.co/docs/
