# `batty` CLI design — foundation & action catalog

A foundation for growing the `batty` command from "open a session at a path"
into a coherent, extensible control surface — informed by the CLI/socket APIs of
**herdr**, **supacode**, and **cmux** (surveyed 2026-07-03 for #0254), filtered
through Batty's "simple, Mac-first" bar.

Current state: `batty <path>` opens a session at that path via the `batty://`
URL scheme (#0249–#0251); `version`/`help` exist. It's **one-way** (fire-and-
forget) and has no context awareness. This doc proposes the grammar, the
context model, the IPC decision, and a tiered catalog so v1 starts on a good
footing and grows without rework.

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
No `surface`, no `workspace`, no `worktree`.

### 1.2 Context: how a command knows where it's running
The load-bearing foundation. Every app injects IDs into each surface's env and
defaults CLI flags to them (supacode `SUPACODE_SURFACE_ID`, cmux
`CMUX_SURFACE_ID`, herdr similar). Batty must do the same:

- Inject at surface spawn: **`BATTY_SESSION_ID`, `BATTY_PANE_ID`, `BATTY_TAB_ID`**
  (and `BATTY_SURFACE_ID` == tab id). (Mechanism + caveats already scoped in the
  CLI-context discussion; supacode prepends `export …;` to the launch command.)
- Every context-sensitive verb resolves target as: explicit `--session/--pane/--tab`
  flag → else the `BATTY_*` env → else the app's focused element.
- `batty whoami` prints the current context **from env alone** — no app round-trip,
  no socket. (cmux calls this `identify`.)

### 1.3 IPC: one-way vs two-way — the pivotal fork
- **Mutations** (split, new, close, rename, focus, notify) are fire-and-forget →
  keep using the **`batty://` URL scheme** Batty already has. Simple, no daemon.
- **Queries/reads** (list, read-screen, wait, subscribe) need a response →
  require a **request/response Unix socket** (what all three use: newline-
  delimited JSON with an `id`, `result`/`error`).
- **Recommendation:** build the whole mutation surface on the URL scheme first
  (no socket). Add a **minimal read-only Unix socket** later, and only if the
  query/agent-wait features earn it. Design the grammar so socket-backed verbs
  slot in without changing the one-way ones.
- **Amendment (#0257, 2026-07-06):** *topology* queries (`list`, `session info`)
  don't actually need the socket — the app can maintain an atomic, debounced
  JSON state snapshot (`~/Library/Application Support/Batty/state.json`) that
  the CLI reads directly. A third IPC path between one-way URL and two-way
  socket; see #0257 § "Agent context & session topology". The socket remains
  required only for live reads (`read`, `wait`, `send`, `events`). Two related
  one-way tricks from the same revision: mutation URLs carry **explicit target
  ids** (resolved flag → env → focused) so a background-session pane can be
  split without stealing focus, and creation verbs use **client-generated
  UUIDs** so the CLI can print the new object's id despite fire-and-forget IPC.

### 1.4 Machine-readable output & scripting hygiene
- `--json` on every query verb (cmux does this pervasively) — agents/scripts are
  first-class consumers.
- Meaningful exit codes; `send`-style verbs accept stdin piping; quiet by default.
- `batty ping` (is Batty running) and `batty capabilities` (list supported verbs)
  are cheap introspection worth having early (both in cmux).

---

## 2. Action catalog

Legend: **[1-way]** works over the URL scheme · **[2-way]** needs the read
socket · fit tags: **[core]** on-brand now · **[activity]** agent-activity
display · **[adv]** advanced/automation, adopt only if needed · **[skip]**
off-mission for Batty.

### A. Structure — sessions / panes / tabs  [core, 1-way]
- `batty session new [path]` — open a session (today's `batty <path>`; keep as an alias). *(supacode `repo worktree-new`, herdr `workspace.create`, cmux `new-workspace`)*
- `batty pane split [-h|-v]` — split the focused/target pane. *(all three: `pane.split` / `surface.split`)* — panes now distribute evenly (1/n, **#0255 shipped**).
- `batty pane hide` / `batty pane show <id>` — hide/restore a pane (**#0256 shipped**: surface kept alive, slot retained). `hide` targets the calling/focused pane; `show` needs an id (a hidden pane has no calling context). *(no direct competitor equivalent — Batty-specific)*
- `batty tab new [-c <cmd>]` — new tab in the focused pane, optionally running a command. *(supacode `tab new -i`, herdr `tab.create`)*
- `batty pane close` / `batty tab close` / `batty session close`. *(all three)*
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
- `batty notify --title <t> [--body <b>] [--sound]` — post a notification into
  Batty's **bell feed** (and optional system notification). *(herdr `notification.show`, cmux `notify`)* — **highest-value, most on-brand**: Batty already has the feed + AI summaries; this routes agent events into it.
- `batty status <key> <text> [--icon <sf-symbol>] [--color <hex>]` /
  `batty status clear <key>` — a live status pill on the session's sidebar row
  (e.g. `batty status build "compiling"`). *(cmux `set-status`/`clear-status`)* —
  lets an agent show **busy / waiting / done** without a presence subsystem.
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
- `batty whoami` — current session/pane/tab **[1-way / local env]** (no socket). *(cmux `identify`)*
- `batty ping` — is Batty running **[could be 1-way probe]**. *(all three)*
- `batty list [sessions|panes|tabs] [--json]` — enumerate live state **[2-way]**. *(all three: `*.list`)*
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
  surface. *(herdr `pane.send_text`, cmux `surface.send_text`/`send_key`, supacode `surface focus -i`)* — powerful for driving agents/scripts, but it's real automation surface; keep out of the simple core.
- `batty read [--lines N] [--source visible|recent]` — read screen/scrollback. *(herdr `pane.read`)* — needs the socket; useful for agents reading output.
- `batty wait <idle|done|blocked> [--pane]` — block until an agent/command reaches a state. *(herdr `wait agent-status`)* — needs agent-state + events.
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
3. **`whoami`/`identify`** from env — free, no socket. **Recommended early.**
4. **`send-text`/`send-key`** — programmatically drive a terminal (adv).
5. **`read`** screen/scrollback — let a script/agent read output (adv, socket).
6. **`wait`** for idle/done — block a script until an agent finishes (adv, socket + events).
7. **`events subscribe`** — stream state changes as newline JSON (adv, socket).
8. **`pane zoom` / `swap` / `move`** — richer layout control than just split/close.
9. **`layout export/apply`** — declarative layouts; could merge with Batty's presets.
10. **`capabilities`** — self-describing CLI so agents can discover verbs.

---

## 4. Recommended phased foundation

- **Tier 0 — foundation (do first):** the `batty <noun> <verb>` grammar; inject
  `BATTY_*` context env; `--session/--pane/--tab` resolution; `--json` convention;
  `batty whoami`; keep `batty <path>` working as `batty session new`. Decide IPC:
  **URL scheme for mutations now, reserve a read socket for later.**
- **Tier 1 — core mutations (all 1-way, no socket):** `pane split`, `tab new`,
  `pane/tab/session close`, `pane/tab/session focus`, `session/tab rename`,
  `notify`, `open`, `settings`. A genuinely useful CLI with zero daemon.
- **Tier 2 — agent activity display:** `status` (+ `progress`/`log`) sidebar pills
  routed into Batty's session UI + bell feed. The "present agent activity" ask,
  kept simple.
- **Tier 3 — two-way (only if earned):** stand up the minimal read socket; add
  `list`, `read`, `send`/`send-key`, `wait`, `events subscribe`. This is the real
  complexity step — gate it on a concrete need.

Guardrails throughout: keep the noun set to session/pane/tab/window; every verb
must feel like a native Mac action with a keyboard/menu equivalent where it makes
sense; no feature should require the socket to *exist* for the app to run.

---

## References
- `docs/supacode-feature-review.md` — the simplicity-first lens and supacode CLI (`worktree`/`tab`/`surface`/`repo`/`settings` + `supacode://` deeplinks).
- #0254 — the herdr/supacode/cmux exploration umbrella (this doc is its CLI thread).
- #0249/#0250/#0251 — the existing `batty` CLI + `batty://` scheme.
- herdr socket API (`herdr.dev/docs/socket-api/`), cmux API (`cmux.com/docs/api`).
