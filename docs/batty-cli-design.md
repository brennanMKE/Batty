# `batty` CLI design — foundation & action catalog

A foundation for growing the `batty` command from "open a session at a path"
into a coherent, extensible control surface — informed by the CLI/socket APIs of
**herdr**, **supacode**, and **cmux** (surveyed 2026-07-03 for #0254), filtered
through Batty's "simple, Mac-first" bar.

Current state (2026-08-10): `batty [<path>]` / `batty new [<path>]` creates a
Session via the `batty://` URL scheme. The shipped XPC broker supports `ping`,
`status`, `list`, `session info`, `pane split`, `pane close`, and `notify`;
`batty id` / `whoami` reads the injected `BATTY_*` context locally. The full
noun/verb catalog below is still a proposal, not a claim that every listed
command exists. For the exact as-built surface, use `docs/batty-cli-install.md`
or `batty --help`.

---

## 1. Foundational decisions (get these right first)

These shape everything; the action list is secondary.

### 1.1 Grammar: `batty <noun> <verb> [args]`
All three converge on noun-verb (`herdr pane split`, `supacode surface split`;
cmux uses flat aliases like `new-split` over a `surface.split` socket method).
Adopt **`batty <noun> <verb>`** with short flat aliases where ergonomic.

**Batty's nouns are simpler than the others** — a real advantage worth
preserving:

| Others | Batty | Note |
|---|---|---|
| workspace / repo / worktree | **session** | Batty's top unit; no git/worktree coupling |
| pane | **pane** | a leaf of the split tree |
| tab | **tab** | one terminal (Batty's tab *is* the surface) |
| surface (separate from tab) | — | Batty collapses surface into tab: one fewer noun |
| window | **window** | multi-window exists |

So the noun set is **`session`, `pane`, `tab`, `window`** (+ app-level verbs).
No `workspace`, no `worktree`; `surface` is not a fifth noun, but it is an
accepted **alias** for `tab` (see §1.2).

### 1.2 Context: how a command knows where it's running
The load-bearing foundation. Every app injects IDs into each surface's env and
defaults CLI flags to them (supacode `SUPACODE_SURFACE_ID`, cmux
`CMUX_SURFACE_ID`, herdr similar). Batty must do the same:

- Inject at surface spawn: **`BATTY_SESSION_ID`, `BATTY_PANE_ID`, `BATTY_TAB_ID`**.
  Batty's Surface registry (`Concepts.md`: `[UUID: ghostty_surface_t]`) is
  keyed by tab id, so `BATTY_TAB_ID` **is** the surface id — no separate
  `BATTY_SURFACE_ID` is injected. `pane` and `tab` are the CLI nouns
  (`Concepts.md`); `surface` is an accepted alias for `tab`, not a
  separate addressable thing — kept as an alias rather than rejected
  outright because a Tab owns a Terminal Session *today* but may host a
  web view or another view type later, and "Terminal Session" is
  terminal-specific where `tab`/`surface` stay generic across view types.
  **Landed in #0281**, via libghostty's own `env = KEY=VALUE` config
  directive (`TabRuntime.applyShellAndAppearancePreferences`) rather than
  supacode's `export …;` command-line prepend this section originally
  anticipated — the config directive sets the spawned process's
  environment directly, works whether or not a custom shell is
  configured, and has no shell-quoting hazard.
- Every context-sensitive verb resolves target as: explicit `--session/--pane/--tab`
  flag → else the `BATTY_*` env → else the app's focused element. **Landed in
  #0281** as `BattyTargetResolver` (`BattyCLICore`), retrofitted onto
  `batty session info`.
- `batty id` (alias `whoami`) prints the current context **from env alone** —
  no app round-trip, no socket. **Landed in #0281**; `id` is the primary
  name, `whoami` a supported alias. (cmux calls this `identify`.)

### 1.3 IPC: shipped hybrid transport

The earlier URL/snapshot/socket recommendation was superseded by #0265–#0274:

- **Session creation** remains on `batty://` because Launch Services can start
  the app and deliver the path with very little machinery. It is one-way, so
  success only confirms that `/usr/bin/open` accepted the URL.
- **Queries and acknowledged mutations** use a launchd-managed broker plus a
  direct anonymous XPC endpoint exported by the app. The broker is only the
  rendezvous; after endpoint handoff the CLI talks directly to the app.
- **Local context** uses injected `BATTY_SESSION_ID`, `BATTY_PANE_ID`, and
  `BATTY_TAB_ID` environment variables. `batty id` needs no IPC; targetable XPC
  verbs resolve explicit flag → environment id → focused app element.
- The proposed JSON snapshot and Unix socket were not built. Future live reads
  such as `read`, `wait`, `send`, or event streaming should first evaluate the
  existing XPC channel rather than assuming a fourth transport is necessary.

### 1.4 Machine-readable output & scripting hygiene
- `--json` on every query verb (cmux does this pervasively) — agents/scripts are
  first-class consumers.
- Meaningful exit codes; `send`-style verbs accept stdin piping; quiet by default.
- `batty ping` (is Batty running) and `batty capabilities` (list supported verbs)
  are cheap introspection worth having early (both in cmux).

---

## 2. Action catalog

Transport tags in this historical catalog describe the original proposal.
The shipped implementation instead uses **[URL]** for Session creation,
**[XPC]** for live queries and acknowledged mutations, and **[local]** for
environment identity. Fit tags remain: **[core]** on-brand now ·
**[activity]** agent-activity display · **[adv]** advanced/automation, adopt
only if needed · **[skip]** off-mission for Batty.

### A. Structure — sessions / panes / tabs  [core, 1-way]
- `batty session new [path]` — open a session (today's `batty <path>`; keep as an alias). *(supacode `repo worktree-new`, herdr `workspace.create`, cmux `new-workspace`)*
- `batty pane split [-h|-v]` — split the focused/target pane. **Shipped over XPC**; also supports `-c/--command`, `--pane`, and `--view`. *(all three: `pane.split` / `surface.split`)* — panes distribute evenly (1/n, #0255).
- `batty pane hide` / `batty pane show <id>` — hide/restore a pane (**#0256 shipped**: surface kept alive, slot retained). `hide` targets the calling/focused pane; `show` needs an id (a hidden pane has no calling context). *(no direct competitor equivalent — Batty-specific)*
- `batty tab new [-c <cmd>]` — new tab in the focused pane, optionally running a command. *(supacode `tab new -i`, herdr `tab.create`)*
- `batty pane close` **shipped over XPC**; `batty tab close` and `batty session close` remain proposed. *(all three)*
- `batty window new` — new window. *(Batty-specific; #0234)*

### B. Focus / navigation  [core, 1-way]
- `batty pane focus <up|down|left|right|id>` · `batty pane next|prev`. *(herdr `pane.focus_direction`/`neighbor`, cmux `surface.focus`)*
- `batty tab focus <n|id>` · `batty tab next|prev`. *(herdr `tab.focus`)*
- `batty session focus <name|id>`. *(herdr `workspace.focus`, cmux `select-workspace`)*
- `batty pane zoom [--on|--off|--toggle]` — maximize one pane. *(herdr `pane.zoom`)*
- `batty pane swap <dir>` · `batty pane move <dest>` — rearrange. *(herdr `pane.swap`/`move`)*

### C. Naming / metadata  [core, 1-way]
- `batty session rename <name>` · `batty tab rename <name>`. *(herdr `tab.rename`/`workspace.rename`)* — already discussed as the first CLI-context feature.
- `batty tab color <color>` / `batty session color <color>` — per-tab/session tint. *(supacode & cmux have per-tab/repo color)* — optional polish.

### D. Activity display for agents  [activity, 1-way]  ← the "present agent activity" ask
This is the clean, **simple** way to surface agent activity **without** supacode/
herdr's OSC-3008 Ghostty patch. An agent or script just calls these; Batty
renders them in the session sidebar / pane chrome / bell feed it already has.
- `batty notify --title <t> [--body <b>] [--sound] [--tab <id>]` — post a
  notification into Batty's **Bell Feed** (and optional system notification).
  **Shipped over XPC.** *(herdr `notification.show`, cmux `notify`)*
- A future activity-status command (originally sketched as
  `batty status <key> <text>` / `batty status clear <key>`) — a live status
  pill on the Session's Sidebar row
  (e.g. `batty status build "compiling"`). *(cmux `set-status`/`clear-status`)* —
  lets an agent show **busy / waiting / done** without a presence subsystem.
  The bare name now conflicts with the shipped `batty status` live-state query,
  so this proposal needs a different grammar before implementation.
- `batty progress <0..1> [--label]` / `batty progress clear` — a progress bar on
  the row. *(cmux `set-progress`)* — optional.
- `batty log <msg> [--level info|warn|error]` — append to a per-session activity
  log. *(cmux `log`)* — optional.

> Design note: model these as a small, explicit "activity" surface Batty owns
> (feed + status pill + optional progress), fed by the CLI. That gives 80% of
> "agent presence" at 5% of the cost, and stays Mac-native. Full agent-state
> objects (herdr `pane.report_agent` working/idle/blocked/done + `agent.list`)
> are the heavier version — see §D-adv.

### E. Introspection / query  [2-way unless noted]
- `batty id` (alias `whoami`) — current session/pane/tab **[1-way / local env]** (no socket). **Landed (#0281).** *(cmux `identify`)*
- `batty ping` — check whether the broker is reachable **[XPC, shipped]**. *(all three)*
- `batty status` — live process and topology counts **[XPC, shipped]**.
- `batty list [sessions|panes|tabs] [--json]` — enumerate live state **[XPC, shipped]**. *(all three: `*.list`)*
- `batty session info [--session <id>] [--json]` — one Session's topology slice **[XPC, shipped]**.
- `batty capabilities [--json]` — list supported verbs **[2-way or static]**. *(cmux)*

### F. App / window / theme  [core, 1-way]
- `batty open` — activate/foreground Batty. *(supacode `open`)*
- `batty settings [section]` — open Settings (to a pane). *(supacode `settings`)*
- `batty sidebar toggle` / `batty window …`. *(Batty menu actions)*
- `batty theme set <name>` / `batty theme list` — Batty has a theme catalog already.

### G. Meta  [core]
- `batty version` · `batty help` · `batty completions <bash|zsh|fish>` · global `--json`.

### Advanced / automation (adopt only if the workflow demands)  [adv, 2-way]
- `batty send <text>` / `batty send-key <enter|esc|…>` — inject text/keys into a
  surface. *(herdr `pane.send_text`, cmux `surface.send_text`/`send_key`, supacode `surface focus -i`)* — powerful for driving agents/scripts, but it's real automation surface; keep out of the simple core. Evaluate the existing XPC channel first.
- `batty read [--lines N] [--source visible|recent]` — read screen/scrollback. *(herdr `pane.read`)* — needs an acknowledged reply; the existing XPC channel is the starting point.
- `batty wait <idle|done|blocked> [--pane]` — block until an agent/command reaches a state. *(herdr `wait agent-status`)* — needs agent-state + events and may need a streaming extension to XPC.
- `batty status/agent report <working|idle|blocked|done>` + `batty events subscribe` — full agent-state objects + a newline-JSON event stream. *(herdr `pane.report_agent`, `events.subscribe`)* — the heavy "agent presence" tier; a big step, likely off-mission.
- `batty layout export|apply` — declarative save/restore of a pane tree. *(herdr `layout.export/apply`)* — overlaps Batty's existing **layout presets**; could unify.

### Deliberately skip (off-mission — consistent with `docs/supacode-feature-review.md`)
git worktree verbs, GitHub/PR, per-repo run-scripts, plugin system, in-app
browser automation, remote-tmux attach, telemetry. These are what the other apps
are *for*; adopting them re-bloats Batty.

---

## 3. Discovery — actions worth knowing about (you asked)

Beyond the obvious split/new/close, these surfaced from the competitors and are
worth a look:

1. **Activity pills / progress / log** (cmux `set-status`/`set-progress`/`log`) —
   the pragmatic "show what the agent is doing" without OSC hacks. **Recommended.**
2. **`notify`** into the existing bell feed (herdr/cmux) — trivially on-brand. **Recommended.**
3. **`id` (alias `whoami`)/`identify`** from env — free, no socket. **Landed (#0281).**
4. **`send-text`/`send-key`** — programmatically drive a terminal (adv).
5. **`read`** screen/scrollback — let a script/agent read output (adv, socket).
6. **`wait`** for idle/done — block a script until an agent finishes (adv, socket + events).
7. **`events subscribe`** — stream state changes as newline JSON (adv, socket).
8. **`pane zoom` / `swap` / `move`** — richer layout control than just split/close.
9. **`layout export/apply`** — declarative layouts; could merge with Batty's presets.
10. **`capabilities`** — self-describing CLI so agents can discover verbs.

---

## 4. Recommended phased foundation

- **Tier 0 — foundation (partly shipped):** command/subcommand grammar,
  `BATTY_*` context env, target resolution, `--json` on query commands, and
  `batty id`/`whoami` are in place. Bare `batty <path>` remains the default
  `new` shorthand. The shipped transport is URL + XPC + local environment.
- **Tier 1 — core mutations (partly shipped):** `pane split`, `pane close`,
  and `notify` use acknowledged XPC. `tab new`, other close/focus/rename
  verbs, `open`, and `settings` remain proposed.
- **Tier 2 — agent activity display:** `status` (+ `progress`/`log`) sidebar pills
  routed into Batty's session UI + bell feed. The "present agent activity" ask,
  kept simple.
- **Tier 3 — richer two-way behavior (partly shipped):** `status`, `list`, and
  `session info` use XPC today. `read`, `send`/`send-key`, `wait`, and event
  subscription remain proposed; extend or validate XPC before adding another
  transport.

Guardrails throughout: keep the noun set to session/pane/tab/window; every verb
must feel like a native Mac action with a keyboard/menu equivalent where it makes
sense; no CLI feature should be required for the app itself to run.

---

## References
- `docs/supacode-feature-review.md` — the simplicity-first lens and supacode CLI (`worktree`/`tab`/`surface`/`repo`/`settings` + `supacode://` deeplinks).
- #0254 — the herdr/supacode/cmux exploration umbrella (this doc is its CLI thread).
- #0249/#0250/#0251 — the existing `batty` CLI + `batty://` scheme.
- herdr socket API (`herdr.dev/docs/socket-api/`), cmux API (`cmux.com/docs/api`).
