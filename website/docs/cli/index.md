# Batty command-line reference

Generated from `batty capabilities --json`, Batty 1.5.0. Machine-readable copy: [capabilities.json](capabilities.json).

Run `batty capabilities --json` (`batty-beta` in Batty Beta) for the exact surface of the build you have installed. Back to [Docs](../index.md).

## Top-level commands

### `batty new`

Create a new Batty session rooted at a directory, printing its id and focused pane id.

Hints: none

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `--json` | flag | boolean | no | false |  |  | Emit JSON instead of the two-line session id / pane id text. |
| `--no-wait` | flag | boolean | no | false |  |  | Dispatch the batty:// URL and exit immediately without confirming the new session — the original fire-and-forget behavior. |
| `<path>` | positional | string | no | . |  |  | Directory for the new session. Defaults to the current directory. |

- --json has no effect with --no-wait, which exits before there is anything to report

### `batty ping`

Check whether the Batty broker is reachable.

Hints: read-only, idempotent

No parameters.

### `batty status`

Report live state (pid, uptime, windows, sessions) from a running Batty.

Hints: read-only, idempotent

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `--json` | flag | boolean | no | false |  |  | Emit JSON instead of a plain-text summary. Reports failure states as JSON too, so a script never sees empty stdout. |

### `batty list`

List windows, sessions, panes, and tabs from a running Batty.

Hints: read-only, idempotent

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `--include-dimensions` | flag | boolean | no | false |  |  | Include `frame` and `visibleRect` dimensions in pane objects. Not included by default. |
| `--json` | flag | boolean | no | false |  |  | Emit JSON instead of a plain-text summary. |
| `<scope>` | positional | string | no | sessions | sessions, panes, tabs |  | Restrict the plain-text listing to sessions, panes, or tabs. Defaults to sessions. Ignored by --json, which always reports the full topology — slice it with a tool like jq instead. |

### `batty id`

Print this pane's session/pane/tab id from environment.

Aliases: `whoami`

Hints: read-only, idempotent

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `--json` | flag | boolean | no | false |  |  | Emit JSON instead of a plain-text summary. |

### `batty notify`

Post a notification into the Bell Feed.

Hints: none

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `--body` | option | string | no |  |  |  | Notification body. |
| `--sound` | flag | boolean | no | false |  |  | Request sound, subject to Settings → Notifications → "Play sound". |
| `--tab` | option | string | no |  |  |  | Tab id to attribute the notification to. Falls back to BATTY_TAB_ID, then the focused tab, when omitted. |
| `--title` | option | string | yes |  |  |  | Notification title. |

### `batty mcp`

Serve this CLI's verbs as MCP tools over stdin/stdout.

Hints: idempotent

No parameters.

### `batty capabilities`

Report the verbs and exit-code vocabulary this batty build supports.

Hints: read-only, idempotent

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `--json` | flag | boolean | no | false |  |  | Emit JSON instead of a plain-text summary. |

## `session`

### `batty session info`

Report the calling/target session's topology slice.

Hints: read-only, idempotent

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `--include-dimensions` | flag | boolean | no | false |  |  | Include `frame` and `visibleRect` dimensions in pane objects. Not included by default. |
| `--json` | flag | boolean | no | false |  |  | Emit JSON instead of a plain-text summary. |
| `--session` | option | string | no |  |  |  | Session id to inspect. Falls back to the focused session when omitted. |

### `batty session focus`

Select a session and activate its window.

Hints: idempotent

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `<id>` | positional | string | no |  |  |  | Session id to focus. Falls back to BATTY_SESSION_ID, then the focused session, when omitted. |

### `batty session close`

Close a session, ending every Tab's Terminal Session across its panes.

Hints: destructive

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `--session` | option | string | no |  |  |  | Session id to close. Falls back to BATTY_SESSION_ID, then the focused session, when omitted. |

### `batty session remind`

Set, replace or cancel a session's Reminder.

Hints: none

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `--at` | option | string | no |  |  |  | HH:MM 24-hour: later today, or the time for --tomorrow. |
| `--cancel` | flag | boolean | no | false |  |  | Cancel the session's pending Reminder, if any. |
| `--in` | option | string | no |  |  |  | Fire after a duration: 5m, 2h or 1h30m (1 minute to 7 days). |
| `--json` | flag | boolean | no | false |  |  | Emit JSON instead of a plain-text confirmation. |
| `--note` | option | string | no |  |  |  | The text, as an option (same as the argument; trimmed, up to 500 characters). |
| `--session` | option | string | no |  |  |  | Session id to remind. Falls back to BATTY_SESSION_ID, then the focused session, when omitted. |
| `<text>` | positional | string | no |  |  |  | What to be reminded of (trimmed, up to 500 characters). |
| `--tomorrow` | flag | boolean | no | false |  |  | Fire tomorrow, at --at or the app's default Tomorrow time. |

- specify exactly one of --in, --tomorrow, --at or --cancel
- specify exactly one of --in, --tomorrow, --at or --cancel
- give the text once: as an argument or with --note
- the text or --note is not valid with --cancel
- the text or --note is not valid with --cancel

## `pane`

### `batty pane split`

Split the calling/target pane, printing the new pane's id.

Hints: none

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `-c, --command` | option | string | no |  |  |  | Run this command in the new pane in place of the default shell; with --wait it is typed into the shell instead. |
| `direction` | flag | string | no | horizontal | horizontal (-h, --horizontal), vertical (-v, --vertical) |  | Split direction. Defaults to horizontal. |
| `--json` | flag | boolean | no | false |  |  | Emit JSON (paneID, created, tabID, and with --wait exitCode, durationMs, waitResult) instead of the id. |
| `--pane` | option | string | no |  |  |  | Pane id to split. Falls back to BATTY_PANE_ID, then the focused pane, when omitted. |
| `--path` | option | string | no |  |  |  | Directory for the new pane to monitor (only valid with --view git-status). Resolved to an absolute path. |
| `--pid` | option | integer | no |  |  | 1– | Pin a process-status pane to this pid instead of following a terminal's foreground process. Only valid with --view process-status. |
| `--timeout` | option | number | no | 600 |  | –86400 | Seconds --wait waits, at most 86400. Defaults to 600. The command keeps running after a timeout. |
| `--unique` | flag | boolean | no | false |  |  | With --view <kind>, print the id of an existing visible pane of that kind instead of creating one. viewOptions differences (--path/--pid) do not defeat the match. Requires a non-terminal --view. |
| `--view` | option | string | no | terminal | terminal, git-status, process-status, lm-studio-dashboard, system-metrics |  | Pane content kind for the new pane. Defaults to terminal. |
| `--wait` | flag | boolean | no | false |  |  | Type the command into a shell and wait for it to finish, then report its exit status. Needs bash or zsh. Blocks up to --timeout; MCP callers should pass a timeout below their client's tool-call limit. |

- --unique requires a non-terminal --view <kind> (there is no sensible "the terminal pane" to find)
- --command is not valid with a non-terminal --view <kind> (non-terminal panes have no shell); omitting --view (which defaults to terminal) is fine
- --pid is only valid with --view process-status
- --path is not valid with --view <kind> (only git-status accepts --path)
- --wait requires -c/--command
- --timeout requires --wait

### `batty pane close`

Close every tab in the calling/target pane and remove it from the split.

Hints: destructive

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `--pane` | option | string | no |  |  |  | Pane id to close. Falls back to BATTY_PANE_ID, then the focused pane, when omitted. |

### `batty pane focus`

Focus a pane by id, selecting its session and activating its window.

Hints: idempotent

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `<id>` | positional | string | no |  |  |  | Pane id to focus. Falls back to BATTY_PANE_ID, then the focused pane, when omitted. |

### `batty pane hide`

Hide a pane (the eye-toggle's CLI equivalent), leaving it in the split but out of view.

Hints: idempotent

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `--pane` | option | string | no |  |  |  | Pane id to hide. Falls back to BATTY_PANE_ID, then the focused pane, when omitted. |

### `batty pane show`

Show (un-hide) a pane by id, printing nothing on success.

Hints: idempotent

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `<id>` | positional | string | yes |  |  |  | Pane id to show. Required — no BATTY_PANE_ID/focused-pane fallback (a hidden pane has no shell to run batty from). |

## `tab`

### `batty tab focus`

Focus a tab by id, selecting it, its pane, and its session, and activating its window.

Hints: idempotent

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `<id>` | positional | string | no |  |  |  | Tab id to focus. Falls back to BATTY_TAB_ID, then the focused tab, when omitted. |

### `batty tab new`

Open a new terminal tab in the calling/target pane, printing the tab's id.

Hints: none

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `--background` | flag | boolean | no | false |  |  | Add the tab without selecting it. |
| `-c, --command` | option | string | no |  |  |  | Run this command in the new tab in place of the default shell; the tab stays open after it exits. With --wait it is typed into the shell instead. |
| `--cwd` | option | string | no |  |  |  | Working directory for the new tab. Defaults to the calling tab's, else the pane's active tab's. |
| `--json` | flag | boolean | no | false |  |  | Emit JSON (sessionID, paneID, tabID, and with --wait exitCode, durationMs, waitResult) instead of the id. |
| `--pane` | option | string | no |  |  |  | Pane id to add the tab to. Falls back to BATTY_PANE_ID, then the focused pane, when omitted. |
| `--timeout` | option | number | no | 600 |  | –86400 | Seconds --wait waits, at most 86400. Defaults to 600. The command keeps running after a timeout. |
| `--wait` | flag | boolean | no | false |  |  | Type the command into a shell and wait for it to finish, then report its exit status. Needs bash or zsh. Blocks up to --timeout; MCP callers should pass a timeout below their client's tool-call limit. |

- --wait requires -c/--command
- --timeout requires --wait

## `project`

### `batty project list`

List the saved Projects.

Hints: read-only, idempotent

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `--json` | flag | boolean | no | false |  |  | Emit JSON instead of a plain-text table. Root paths stay absolute. |

### `batty project open`

Open a saved Project as a Session, or focus its Session if one is open.

Hints: none

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `--json` | flag | boolean | no | false |  |  | Emit JSON (sessionID, paneID, created, name) instead of a sentence. |
| `<name>` | positional | string | yes |  |  |  | Name of the saved Project (case-insensitive). |
| `--new` | flag | boolean | no | false |  |  | Open another Session even if one from this Project is already open. |

### `batty project create`

Save a new Project: its root, look, layout and background.

Hints: none

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `--background-digest` | option | string | no |  |  |  | A My Images image by its digest from background list. |
| `--background-file` | option | string | no |  |  |  | A local image file, copied into the Project's background folder. |
| `--background-id` | option | string | no |  |  |  | A Background Sets image by its id (full URL) from background list. |
| `--background-image` | option | string | no |  |  |  | The image's title in background-set. |
| `--background-set` | option | string | no |  |  |  | The Background Sets set of the Project's image (with background-image). |
| `--color` | option | string | no |  | blue, orange, green, pink, teal, red, violet, amber, cyan, brown |  | A palette color. |
| `--color-hex` | option | string | no |  |  |  | A custom color as #RRGGBB. |
| `--from-session` | flag | boolean | no | false |  |  | Take the layout from a live Session, as Save Session as Project does. |
| `--json` | flag | boolean | no | false |  |  | Emit JSON (id, name, rootPath, paneCount, tabCount, created, warnings, appliesOnNextOpen) instead of a sentence. |
| `--layout` | option | string | no |  |  |  | A layout document file path, or - for standard input (not available over MCP; use layout-json). |
| `--layout-json` | option | string | no |  |  |  | A layout document as inline JSON. A layout document is JSON: {"preset": NAME, "panes": [PANE...], "focusedPane": N} fills a preset's slots in order (omit "panes" for all terminals), or {"root": NODE} gives a tree, where NODE is a PANE or {"split": "horizontal"\|"vertical", "children": [NODE, NODE...]}. A PANE is {"kind": "terminal"\|"git-status"\|"process-status"\|"system-metrics"\|"lm-studio-dashboard", "tabs": [TAB...] (terminal only), "repository": DIR (git-status only), "background": BG, "hidden": BOOL, "activeTab": N}. A TAB is {"title", "cwd" (relative to the Project root), "command", "background": BG}. A BG is one of {"id": URL from `batty background list`}, {"set": SET, "image": TITLE}, {"digest": D (My Images)} or {"file": PATH (relative to the current folder)}, plus "opacity" and "terminalOpacity" in percent (0-100). Unknown keys are errors. |
| `--name` | option | string | no |  |  |  | The Project's name (required unless from-session). Names are unique, ignoring case. |
| `--no-background` | flag | boolean | no | false |  |  | Remove the Project's background. |
| `--no-theme` | flag | boolean | no | false |  |  | Follow the Settings Theme (clears the Project's Theme). |
| `--opacity` | option | integer | no |  |  | 0–100 | The Project image's opacity in percent. A first image gets 15; needs an image. |
| `--path` | option | string | no |  |  |  | The Project's root folder: an absolute path to an existing directory (a relative one is resolved against the CLI's current folder). Required on create unless from-session. |
| `--preset` | option | string | no |  | singlePane, horizontalSplit, verticalSplit, threeColumns, threeRows, mainLeftTwoRight, mainRightTwoLeft, mainTopTwoBottom, mainBottomTwoTop, twoByTwoGrid |  | A layout preset, every Pane a terminal. |
| `--session` | option | string | no |  |  |  | The Session id for from-session. Falls back to BATTY_SESSION_ID, then the focused Session. |
| `--startup-command` | option | array | no |  |  |  | Startup commands, one per terminal Tab in slot order. They still need the user's approval at the first open. |
| `--symbol` | option | string | no |  | folder, terminal, code, hammer, tools, package, branch, checklist, extension, macApp, iPhoneApp, web, server, cloud, network, security, link, qrCode, chip, wireless, light, home, art, grid, craft, video, game, document, learning, chart, calendar, social, community, ai, model, map, music |  | A curated Project symbol. |
| `--symbol-name` | option | string | no |  |  |  | Any SF Symbol name. |
| `--terminal-opacity` | option | integer | no |  |  | 0–100 | The terminal's opacity over the background in percent. Default 100. |
| `--theme` | option | string | no |  |  |  | A Theme for both Dark and Light appearance. |
| `--theme-dark` | option | string | no |  |  |  | The Theme for Dark appearance. |
| `--theme-light` | option | string | no |  |  |  | The Theme for Light appearance. |

- --color and --color-hex can't be used together
- --symbol and --symbol-name can't be used together
- use one of --theme, --theme-dark/--theme-light and --no-theme
- use one of --theme, --theme-dark/--theme-light and --no-theme
- use one of --preset, --layout, --layout-json and --from-session
- use one of --background-set/--background-image, --background-id, --background-digest, --background-file and --no-background
- --no-background can't be used with --opacity or --terminal-opacity
- --no-background can't be used with --opacity or --terminal-opacity
- --background-set and --background-image go together
- --background-set and --background-image go together
- --session needs --from-session

### `batty project edit`

Change the given fields of a saved Project.

Hints: idempotent

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `--background-digest` | option | string | no |  |  |  | A My Images image by its digest from background list. |
| `--background-file` | option | string | no |  |  |  | A local image file, copied into the Project's background folder. |
| `--background-id` | option | string | no |  |  |  | A Background Sets image by its id (full URL) from background list. |
| `--background-image` | option | string | no |  |  |  | The image's title in background-set. |
| `--background-set` | option | string | no |  |  |  | The Background Sets set of the Project's image (with background-image). |
| `--color` | option | string | no |  | blue, orange, green, pink, teal, red, violet, amber, cyan, brown |  | A palette color. |
| `--color-hex` | option | string | no |  |  |  | A custom color as #RRGGBB. |
| `--from-session` | flag | boolean | no | false |  |  | Take the layout from a live Session, as Save Session as Project does. |
| `--json` | flag | boolean | no | false |  |  | Emit JSON (id, name, rootPath, paneCount, tabCount, created, warnings, appliesOnNextOpen) instead of a sentence. |
| `--layout` | option | string | no |  |  |  | A layout document file path, or - for standard input (not available over MCP; use layout-json). |
| `--layout-json` | option | string | no |  |  |  | A layout document as inline JSON. A layout document is JSON: {"preset": NAME, "panes": [PANE...], "focusedPane": N} fills a preset's slots in order (omit "panes" for all terminals), or {"root": NODE} gives a tree, where NODE is a PANE or {"split": "horizontal"\|"vertical", "children": [NODE, NODE...]}. A PANE is {"kind": "terminal"\|"git-status"\|"process-status"\|"system-metrics"\|"lm-studio-dashboard", "tabs": [TAB...] (terminal only), "repository": DIR (git-status only), "background": BG, "hidden": BOOL, "activeTab": N}. A TAB is {"title", "cwd" (relative to the Project root), "command", "background": BG}. A BG is one of {"id": URL from `batty background list`}, {"set": SET, "image": TITLE}, {"digest": D (My Images)} or {"file": PATH (relative to the current folder)}, plus "opacity" and "terminalOpacity" in percent (0-100). Unknown keys are errors. |
| `--name` | option | string | no |  |  |  | Rename the Project. Names are unique, ignoring case. |
| `--no-background` | flag | boolean | no | false |  |  | Remove the Project's background. |
| `--no-theme` | flag | boolean | no | false |  |  | Follow the Settings Theme (clears the Project's Theme). |
| `--opacity` | option | integer | no |  |  | 0–100 | The Project image's opacity in percent. A first image gets 15; needs an image. |
| `--path` | option | string | no |  |  |  | The Project's root folder: an absolute path to an existing directory (a relative one is resolved against the CLI's current folder). Required on create unless from-session. |
| `--preset` | option | string | no |  | singlePane, horizontalSplit, verticalSplit, threeColumns, threeRows, mainLeftTwoRight, mainRightTwoLeft, mainTopTwoBottom, mainBottomTwoTop, twoByTwoGrid |  | A layout preset, every Pane a terminal; replaces the layout, which open Sessions pick up at the next open. |
| `--session` | option | string | no |  |  |  | The Session id for from-session. Falls back to BATTY_SESSION_ID, then the focused Session. |
| `--startup-command` | option | array | no |  |  |  | Startup commands, one per terminal Tab in slot order. They still need the user's approval at the first open. |
| `--symbol` | option | string | no |  | folder, terminal, code, hammer, tools, package, branch, checklist, extension, macApp, iPhoneApp, web, server, cloud, network, security, link, qrCode, chip, wireless, light, home, art, grid, craft, video, game, document, learning, chart, calendar, social, community, ai, model, map, music |  | A curated Project symbol. |
| `--symbol-name` | option | string | no |  |  |  | Any SF Symbol name. |
| `<target>` | positional | string | yes |  |  |  | The saved Project's name (case-insensitive) or id. |
| `--terminal-opacity` | option | integer | no |  |  | 0–100 | The terminal's opacity over the background in percent. Default 100. |
| `--theme` | option | string | no |  |  |  | A Theme for both Dark and Light appearance. |
| `--theme-dark` | option | string | no |  |  |  | The Theme for Dark appearance. |
| `--theme-light` | option | string | no |  |  |  | The Theme for Light appearance. |

- --color and --color-hex can't be used together
- --symbol and --symbol-name can't be used together
- use one of --theme, --theme-dark/--theme-light and --no-theme
- use one of --theme, --theme-dark/--theme-light and --no-theme
- use one of --preset, --layout, --layout-json and --from-session
- use one of --background-set/--background-image, --background-id, --background-digest, --background-file and --no-background
- --no-background can't be used with --opacity or --terminal-opacity
- --no-background can't be used with --opacity or --terminal-opacity
- --background-set and --background-image go together
- --background-set and --background-image go together
- --session needs --from-session

## `background`

### `batty background list`

List Background Sets images and My Images.

Hints: read-only, idempotent

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `--json` | flag | boolean | no | false |  |  | Emit JSON (images with set, title, id, source, thumbnailURL, fullURL, catalogURL, downloaded, digest; warnings). |
| `--set` | option | string | no |  |  |  | Only this set (case-insensitive, exact). "My Images" lists My Images. |

## `server`

### `batty server start`

Run a dev server in a terminal Pane and list it in the toolbar's Servers, printing the server's id.

Hints: none

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `<command>` | positional | array | yes |  |  |  | The server command, after --. |
| `--json` | flag | boolean | no | false |  |  | Emit JSON (serverID, name, kind, terminalPaneID, tabID, processPaneID, url, pid, state) instead of the id. |
| `--name` | option | string | no |  |  |  | Name shown in the Servers list. |
| `--no-process-view` | flag | boolean | no | false |  |  | Don't open a Process Status Pane on the server's process. |
| `--pane` | option | string | no |  |  |  | Pane the terminal Pane is split from. Falls back to BATTY_PANE_ID, then the focused pane. |
| `--port` | option | integer | yes |  |  |  | TCP port the server listens on (1-65535). |
| `--split` | option | string | no |  | right, down |  | Where the terminal Pane goes: right (default) or down. |
| `--timeout` | option | number | no | 60 |  | –86400 | Seconds --wait waits, at most 86400. Defaults to 60. |
| `--url` | option | string | no |  |  |  | URL to copy and probe. Defaults to http://127.0.0.1:<port>/. |
| `--wait` | flag | boolean | no | false |  |  | Wait until the server listens, exits, or --timeout passes. |

### `batty server share`

List a server already listening on 127.0.0.1 in the toolbar's Servers and watch its process, printing the server's id.

Hints: idempotent

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `--json` | flag | boolean | no | false |  |  | Emit JSON (serverID, name, kind, processPaneID, url, tailnetURL, pid, state) instead of the id. |
| `--name` | option | string | no |  |  |  | Name shown in the Servers list. |
| `--no-process-view` | flag | boolean | no | false |  |  | Don't open a Process Status Pane on the server's process. |
| `--pane` | option | string | no |  |  |  | Pane the Process Status Pane is split from. Falls back to BATTY_PANE_ID, then the focused pane. |
| `--port` | option | integer | yes |  |  |  | TCP port the server listens on (1-65535). |
| `--split` | option | string | no |  | right, down |  | Where the Process Status Pane goes: right (default) or down. |
| `--tailnet` | flag | boolean | no | false |  |  | Also share the server on your tailnet with tailscale serve. |
| `--url` | option | string | no |  |  |  | URL to copy and probe. Defaults to http://127.0.0.1:<port>/. |

### `batty server serve`

Serve a folder on 127.0.0.1, printing the server's id.

Hints: none

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `<dir>` | positional | string | no |  |  |  | Folder to serve. Defaults to this directory. |
| `--engine` | option | string | no |  | builtin, photon |  | builtin or photon. Defaults to photon when PhotonHTTP's photon is installed, else builtin. photon fails when it isn't installed. |
| `--json` | flag | boolean | no | false |  |  | Emit JSON (serverID, url, root, kind, engine, terminalPaneID, state) instead of the id. |
| `--no-inject` | flag | boolean | no | false |  |  | Built-in server only: serve files byte-for-byte, with no live-reload script in HTML. |
| `--open` | flag | boolean | no | false |  |  | Also open the site in the default browser. |
| `--pane` | option | string | no |  |  |  | photon only: Pane its terminal Pane is split from. Falls back to BATTY_PANE_ID, then the focused pane. |
| `--port` | option | integer | no |  |  |  | Port to listen on (1-65535). Defaults to a free port. |
| `--split` | option | string | no |  | right, down |  | photon only: where its terminal Pane goes: right (default) or down. |

### `batty server list`

List the servers in the toolbar's Servers, one per line: id, name, port, kind (terminal, external, static or photon), state, url.

Hints: read-only, idempotent

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `--json` | flag | boolean | no | false |  |  | Emit JSON ({ servers: [...] }) instead of lines. |

### `batty server stop`

Stop a server Batty started (SIGINT, then SIGTERM, then SIGKILL). Refused for a shared server.

Hints: destructive, idempotent

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `<id>` | positional | string | no |  |  |  | Server id. Omit to name it by --port. |
| `--json` | flag | boolean | no | false |  |  | Emit JSON instead of the id. |
| `--pane` | option | string | no |  |  |  | Accepted for compatibility; has no effect. |
| `--port` | option | integer | no |  |  |  | Port of the server. |

### `batty server restart`

Stop a server Batty started and run its command again. Refused for a shared server.

Hints: destructive

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `<id>` | positional | string | no |  |  |  | Server id. Omit to name it by --port. |
| `--json` | flag | boolean | no | false |  |  | Emit JSON instead of the id. |
| `--pane` | option | string | no |  |  |  | Accepted for compatibility; has no effect. |
| `--port` | option | integer | no |  |  |  | Port of the server. |

### `batty server unshare`

Remove a shared server from the toolbar's Servers without signalling it. Refused for a server Batty started.

Hints: none

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `<id>` | positional | string | no |  |  |  | Server id. Omit to name it by --port. |
| `--json` | flag | boolean | no | false |  |  | Emit JSON instead of the id. |
| `--pane` | option | string | no |  |  |  | Accepted for compatibility; has no effect. |
| `--port` | option | integer | no |  |  |  | Port of the server. |

### `batty server tailnet`

Share a listed server on your tailnet with tailscale serve, printing its id and tailnet URL; --off stops.

Hints: idempotent, open-world

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `<id>` | positional | string | no |  |  |  | Server id. Omit to name it by --port. |
| `--json` | flag | boolean | no | false |  |  | Emit JSON (serverID, url, tailnetURL, state) instead of the id. |
| `--off` | flag | boolean | no | false |  |  | Stop sharing the server on the tailnet. |
| `--pane` | option | string | no |  |  |  | Accepted for compatibility; has no effect. |
| `--port` | option | integer | no |  |  |  | Port of the server. |

## `agent`

### `batty agent install`

Install the Batty skill and MCP server for Claude Code, Codex, Cursor and OpenCode.

Hints: idempotent

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `--dry-run` | flag | boolean | no | false |  |  | Print what would be installed and write nothing. |
| `--project` | option | string | no |  |  |  | Also add a Batty section to this project's AGENTS.md or CLAUDE.md. |
| `--yes` | flag | boolean | no | false |  |  | Write the project section without asking (required when not interactive). |

### `batty agent context`

Print a note telling an AI agent it is in a Batty Pane, from BATTY_* alone.

Hints: read-only, idempotent

| Parameter | Kind | Type | Required | Default | Allowed values | Range | Description |
|---|---|---|---|---|---|---|---|
| `--json` | flag | boolean | no | false |  |  | Emit JSON instead of a plain-text note. |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success. |
| 1 | CLI-side failure — invalid path, malformed id, or a bad option combination. |
| 2 | Broker unreachable — agent not registered, or awaiting SMAppService approval. |
| 3 | Broker answered but no app endpoint was registered, and the app could not be started. |
| 4 | Delivered to the app, which replied with a failure. |
| 5 | The app terminated while the request was in flight. |
| 6 | The app is running but not registered with the broker, and did not re-register within the poll bound. |
| 7 | Could not determine, deterministically, which on-disk app bundle to target. |
| 8 | Reached the app, but the Project's startup commands need approval and the prompt in Batty went unanswered. Nothing was opened. |
| 64 | Invalid CLI syntax (ArgumentParser usage error). |

Every `inputSchema` follows the JSON Schema dialect `https://json-schema.org/draft/2020-12/schema`.
