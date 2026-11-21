# Docs

Batty is a native macOS terminal multiplexer: a window of Sessions, each with Tabs, each Tab split into Panes. An agent running in one of its terminal Panes can drive Batty from the `batty` command-line tool or its MCP server: open Panes beside its work, run commands and wait for them, serve a page, and get the user's attention. Everything on this page is optional. Nothing here happens unless the user or their agent asks for it, and the setup lives in Batty's Settings.

## Are you in Batty?

Batty sets `BATTY_SESSION_ID`, `BATTY_TAB_ID` and `BATTY_PANE_ID` in every terminal Pane:

```sh
env | grep '^BATTY'
```

If they are set, `batty agent context` prints which Session, Tab and Pane you are in and the rules for driving Batty. Add `--json` for a machine-readable reply.

## MCP or CLI

Use the `batty` MCP tools when your host has `batty mcp` registered as an MCP server; otherwise use the `batty` CLI. Run `batty capabilities` (or `batty capabilities --json`) first to see what this Batty offers. An MCP tool's name is its command's verb path with underscores, so `batty server list` is the `server_list` tool. A command or tool given no Session, Tab or Pane acts on the caller's own Pane.

In Batty Beta the command is `batty-beta`. Substitute it everywhere on this page, including the MCP server's name.

## Set up your agent

Each of these is optional, and Settings → Advanced → Command Line and AI Agents can do the same for you. The snippets run the `batty` command, so install it from that section first; it goes in `/usr/local/bin`. `batty agent install` writes the full path to the command instead.

### Claude Code

`batty agent install` sets up every agent host it finds. For Claude Code it stages the Batty plugin, with its MCP entry, skill and a SessionStart hook; for Codex, Cursor and OpenCode it adds the MCP entry and the skill:

<!-- generated:claude-code-plugin.txt -->
```sh
batty agent install
```
<!-- /generated -->

Or add Batty's plugin marketplace in Claude Code, which installs the same plugin: the skill, the MCP server and the SessionStart hook. It runs `batty` from your `PATH`, so install the command first. Use this or `batty agent install`, not both.

<!-- generated:claude-code-marketplace.txt -->
```text
/plugin marketplace add brennanMKE/batty-plugins
/plugin install batty@batty-plugins
```
<!-- /generated -->

Or register only the MCP server by hand:

<!-- generated:claude-code-mcp-add.txt -->
```sh
claude mcp add --scope user batty -- batty mcp
```
<!-- /generated -->

### Codex

Add this to `~/.codex/config.toml`. `batty agent install` writes this marked block:

<!-- generated:codex-config.toml -->
```toml
# batty:begin — managed by `batty agent install`; edits inside this block are replaced
[mcp_servers.batty]
command = "batty"
args = ["mcp"]
env_vars = ["BATTY_SESSION_ID", "BATTY_TAB_ID", "BATTY_PANE_ID"]
# batty:end
```
<!-- /generated -->

### Cursor

Merge this into `~/.cursor/mcp.json`:

<!-- generated:cursor-mcp.json -->
```json
{
  "mcpServers" : {
    "batty" : {
      "args" : [
        "mcp"
      ],
      "command" : "batty"
    }
  }
}
```
<!-- /generated -->

### OpenCode

Merge this into `~/.config/opencode/opencode.json`:

<!-- generated:opencode.json -->
```json
{
  "mcp" : {
    "batty" : {
      "command" : [
        "batty",
        "mcp"
      ],
      "enabled" : true,
      "type" : "local"
    }
  }
}
```
<!-- /generated -->

## Core verbs

One example each. The MCP tool is named beside the command. For the order to use them in, see the Batty skill under More.

### Show status in a Pane

`batty pane split --view git-status --unique` (MCP: `pane_split`) opens a Git Status Pane beside yours, or reuses the one already open. The other views are `process-status`, `system-metrics` and `lm-studio-dashboard`.

### Run a command and wait

`batty tab new -c "make test" --wait --json` (MCP: `tab_new`) runs the command in a new Tab and replies when it exits, with `exitCode` and `waitResult` in the JSON.

### Start a dev server

`batty server start --port 3000 -- npm run dev` (MCP: `server_start`) runs the server in a terminal Pane and adds it to the Servers list.

### Share a server that is already running

`batty server share --port 3000` (MCP: `server_share`) adds a server Batty didn't start to the Servers list.

### Serve a folder

`batty server serve site --port 8080` (MCP: `server_serve`) serves a static folder. See Share a page from your project below.

### List servers

`batty server list --json` (MCP: `server_list`) prints each server's port, state and URL.

### Get the user's attention

`batty notify --title "Tests passed" --body "Ready for review"` (MCP: `notify`) posts a notification.

### Set a reminder

`batty session remind "Check the deploy" --in 30m` (MCP: `session_remind`) reminds the user about this Session later.

## Viewing pages

Batty has no web view. To look at or test a page, use the webdriver the developer has named, for example `safaridriver` (the developer runs `safaridriver --enable` once), against the localhost or tailnet URL from `batty server list`. Batty never starts a browser automation tool.

## Share a page from your project

The local way for an agent to publish a web page and hand the user a link. Each step shows the CLI command and its MCP tool. This describes `server serve` as Batty 1.5.0 ships it.

### 1. Write the files

Write the static files (HTML, CSS, JS) into a folder in the project, for example `site/`.

### 2. Serve the folder

`batty server serve site --port 8080` (MCP: `server_serve`) serves the folder on 127.0.0.1, and the server appears in the Servers list. When PhotonHTTP's `photon` command is installed, `serve` runs `photon serve <abs path>/site --host 127.0.0.1 --port 8080` in a terminal Pane, where photon prints `listening 127.0.0.1:8080`. Otherwise Batty's built-in server serves the folder and reloads open pages when a file changes.

`--engine builtin` always uses the built-in server; `--engine photon` uses `photon` only. PhotonHTTP is optional and Batty doesn't bundle it. **Settings → General → Servers** shows whether it is installed, and **Install PhotonHTTP…** runs the installer in a new terminal Pane when the user clicks it. It needs macOS 15 or later and a Swift 6.4 toolchain, and installs `photon` to `/usr/local/bin`, which may ask for an administrator password:

```sh
curl -fsSL https://photon-http.sstools.co/install.sh | bash
photon --help
```

See [PhotonHTTP getting started](https://photon-http.sstools.co/docs/getting-started.md). When `photon` is missing, `--engine photon` stops before opening a Pane with:

```
`photon` (PhotonHTTP) isn't installed. Install it from Settings, or run `curl -fsSL https://photon-http.sstools.co/install.sh | bash` (macOS 15+, Swift 6.4 toolchain), then check with `photon --help`. See https://photon-http.sstools.co/docs/getting-started.md
```

### 3. Give the user the link

`batty server list` (or `--json`; MCP: `server_list`) prints the `http://127.0.0.1:8080/` URL. Print it or copy it for the user.

### 4. Share it on the tailnet, only if asked

Only when the user asks to open the page from another device: `batty server tailnet --port 8080` (MCP: `server_tailnet`) runs `tailscale serve --bg --https=8080 http://127.0.0.1:8080` and prints the tailnet URL, which `batty server list --json` also shows as `tailnetURL`. The URL opens on the user's other devices on their tailnet. It needs Tailscale with HTTPS certificates turned on. Tailnet sharing is opt-in and never automatic.

### 5. Clean up

If you shared it, run `batty server tailnet --port 8080 --off`, then `batty server stop --port 8080` (MCP: `server_stop`). Batty removes only the tailnet mappings it added.

## Close what you open

When you are done, close the Panes and Sessions you created, and only those: `batty pane close --pane <id>` (MCP: `pane_close`) and `batty session close` (MCP: `session_close`).

## Global instructions

Give this prompt to your agent once, so every new session knows about Batty:

<!-- generated:global-instructions-prompt.txt -->
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
<!-- /generated -->

## Versions

- 1.5.0: `agent context`, `agent install`, `mcp`, `tab new`, `--wait`, `server` and the Servers list.
- 1.4.0: `session remind`.
- 1.3.0: Projects.
- 1.2.0: `pane split --view` with `--unique`, and `capabilities --json`.

## More

- [CLI reference](cli/index.md)
- [Batty skill](skill/batty-cli-skill-latest.zip)
- [Claude Code plugin marketplace](https://github.com/brennanMKE/batty-plugins)
- [Changelog](../changelog.html)
- [Batty on GitHub](https://github.com/brennanMKE/Batty)
