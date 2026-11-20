# AI Agents and Servers

Everything on this page is optional and stays off until you set it up; Batty works fine on its own. Coding agents such as Claude Code, Codex, Cursor and OpenCode, running in a terminal Pane, can drive Batty with the `batty` command-line tool or its MCP server. In Batty Beta the command is `batty-beta`.

## What an agent knows

Every terminal Pane sets `BATTY_SESSION_ID`, `BATTY_TAB_ID` and `BATTY_PANE_ID`. `batty agent context` prints which Session, Tab and Pane the agent is in, plus the rules for driving Batty; outside Batty it prints nothing. The MCP server's instructions name the same Pane, and a command or tool given no target acts on the caller's own Pane.

## Setting it up

Open **Settings → Advanced → Command Line and AI Agents**. There you can install the command-line tool (`/usr/local/bin/batty`), and the MCP server and agent guidance for each agent Batty detects: tick the agents, click **Install Selected…**, check the preview, then click **Install**. The MCP server works without the command-line tool.

`batty agent install` does the same from a shell; add `--dry-run` to preview it. Batty offers nothing at launch. After an app update it quietly refreshes only what you installed.

## What is written where

- **Claude Code** — a local plugin named `batty`, staged in `~/Library/Application Support/Batty/AgentPlugin/`, with the skill, the MCP server and a SessionStart hook that runs `batty agent context`. It is installed with `claude plugin`.
- **Codex** — the skill, and a marked block in `~/.codex/config.toml` that passes the three `BATTY_*` variables. The file is backed up first, and later installs replace only that block.
- **Cursor** and **OpenCode** — the skill, and Batty's entry in `~/.cursor/mcp.json` or `opencode.json`. The file is backed up first and only Batty's key changes.
- The skill is also placed in `~/.agents/skills`.

## Instructions files (optional)

In **Agent Instructions (optional)**, **Add to Project…** adds a marked Batty section to a project's `AGENTS.md` or `CLAUDE.md` after showing a preview. **Copy Prompt** copies a prompt to give your agent; the agent then adds or updates a Batty section in its own global instructions file. Batty never edits those global files itself.

## Removing it

Click **Remove…** on an agent's row. Removed files move to `AgentGuidanceBackups` in Batty's Application Support folder. To remove a Batty section from a global instructions file, ask the agent or edit the file.

## What agents can do

- Open a status Pane: `batty pane split --view git-status --unique`.
- Run a command and get its exit status: `batty tab new -c "make test" --wait`, or `batty pane split -c "make test" --wait`.
- Post to the Bell Feed: `batty notify --title "Tests passed"`.
- Set a Reminder: `batty session remind`.
- Close what they opened: `batty pane close` and `batty session close`.

Each command has a matching MCP tool. `batty capabilities` lists them all.

## Servers

`batty server start --port 3000 -- npm run dev` runs a dev server in a terminal Pane, and a Process Status Pane watches it. `batty server share --port 3000` lists a server that is already running; Batty never stops it, and `batty server unshare --port 3000` or **Remove from List** takes it off the list. `batty server list`, `batty server stop --port 3000` and `batty server restart --port 3000` do what they say.

The **Servers** toolbar button appears only while a server is listed, or always with **Settings → General → Servers → Always show Servers in the toolbar**. Each row has **Copy URL** and a menu with **Open in Browser**, **Show Terminal**, **Restart** and **Stop**.

## Serving a folder

`batty server serve ./site` runs PhotonHTTP's `photon serve` on 127.0.0.1 in a terminal Pane. PhotonHTTP is optional and installed separately (macOS 15 or later, Swift 6.4 toolchain):

```
curl -fsSL https://photon-http.sstools.co/install.sh | bash
```

It installs to `/usr/local/bin`; check it with `photon --help`. See https://photon-http.sstools.co/docs/getting-started.md. Without it, `serve` stops and tells you how to install it.

To share a page: write the files into a project folder, run `batty server serve` on it, give the localhost URL from `batty server list`, share on the tailnet only if asked, and stop the server when done.

## Tailnet sharing

Sharing on your tailnet is opt-in for each server. **Share on Tailnet**, or `batty server tailnet --port 3000` (`--off` to stop), runs `tailscale serve` for that port. It is offered only while Tailscale is running; **Copy Tailnet URL** copies the address. Batty removes only mappings it made, including when it quits. A mapping that was already in place shows "Shared on Tailnet outside Batty" and is left alone.

## Viewing pages

Batty has no web view. An agent that needs to look at or test a page uses the webdriver you told it about, for example `safaridriver` (run `safaridriver --enable` once), against the URL from `batty server list`. Batty never starts a browser automation tool.

## More

`batty capabilities` lists every command and flag this build of Batty supports.
