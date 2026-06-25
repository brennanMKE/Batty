# supacode feature review — what (not) to adopt for Batty

A survey of [supacode](https://supacode.sh) (website + cloned repo at `../supacode`)
and a simplicity-first recommendation of which features Batty should adopt.

**Bottom line up front:** supacode and Batty are *different products*. supacode is
"the command center for coding agents" — a heavyweight orchestrator for running
many CLI coding agents (Claude Code, Codex, Copilot, Kiro, OpenCode, Pi) in
parallel, each in its own **git worktree**, with **GitHub** PR/CI integration.
Batty is the opposite by design (`PRD.md`): a *simple, single-developer,
tmux-lite* multiplexer — "the 20% of tmux I actually use, with a real GUI."
Most of what makes supacode *supacode* (agent orchestration, worktree lifecycle,
GitHub integration, a per-repo script system) is exactly what Batty's PRD lists
as a **non-goal**. Adopting that core would turn Batty into a second supacode.

So the useful question isn't "what does supacode have" — it's "which of
supacode's *small, generic, native* affordances would make Batty better without
costing its simplicity." That list turns out to be short, because **Batty already
has most of the light wins** (command palette, rebindable shortcuts, layout
presets, theme/appearance, bell feed, CLI, AI naming). The real gaps are a
handful of self-contained terminal/UX features.

---

## 1. supacode feature inventory (condensed)

Tags: **[CORE]** central to the coding-agent identity · **[GEN]** generic
multiplexer feature · **[HEAVY]** needs significant infra · **[LIGHT]**
self-contained. Full code references are in the source inventory; categories
mirror the repo layout.

### A. Agent orchestration **[CORE / HEAVY]**
Hooks injected into six agents' config dirs that emit a **supacode-private escape
sequence** carrying agent state (`busy`/`awaiting_input`/`idle`/`notify`). The
sequence is `ESC]3008;<action>=<agent>;event=…ESC\` — supacode calls it a "UAPI
hierarchical context signal," but **"OSC 3008" is not a standard terminal code**;
it's a number supacode chose for its own protocol and made work by **patching
Ghostty** (`patches/ghostty-osc3008-context-signal.patch` adds a new
`GHOSTTY_ACTION_CONTEXT_SIGNAL`). Stock terminals ignore it. On top of that:
live **agent presence badges** on sidebar rows & tabs; a `kill(pid,0)` liveness
sweep; presence persisted across relaunch; rich agent notifications (title+body
ride the same stream, so it works over SSH); a "CLI skill" file installed so
agents learn the `supacode` CLI; auto-update of agent integrations. *Note for
Batty:* this whole feature requires **forking/patching Ghostty**, whereas Batty
consumes prebuilt `libghostty-spm` — another reason it's off-mission here.

### B. Git worktree management **[CORE / HEAVY]**
Each sidebar row **is a git worktree** (not a directory). Create (with
branch/base/fetch/name options + random name generator), archive/unarchive,
delete (with branch deletion), per-repo setup/archive/delete scripts, auto-delete
archived worktrees after N days, auto archive/delete on PR-merged, copy
ignored/untracked files into new worktrees, rename branch, branch-prefix nesting
in the sidebar, pinning. Backed by a bundled `git-wt` (`wt`) binary.

### C. GitHub integration **[CORE / HEAVY]**
Via the `gh` CLI: PR tracking per branch, PR status badges (OPEN/DRAFT/MERGED…),
a **CI checks ring + popover** with per-check status, merge-queue awareness, and
command-palette PR actions (ready-for-review, merge w/ strategy, close, re-run
failed jobs, copy failing-job URL / CI logs, open failing check), open-PR-in-
browser shortcut. Global on/off toggle.

### D. Terminal multiplexing **[GEN]**
Per-worktree tabs + splits (binary tree, zoomable), **session persistence via a
bundled `zmx` daemon** (shells survive quit & reattach), layout persistence to
JSON, **in-terminal search** (exposes Ghostty's search overlay), per-tab tint
colors, a "script running" progress stripe, terminal theme sync to app
appearance, hide-single-tab-bar, **SSH remote surfaces (beta)**.

### E. Script system **[CORE / LIGHT–MED]**
Per-repo lifecycle scripts (setup/archive/delete) + arbitrary named run-scripts
(primary Run = Cmd-R, others in a menu) + global scripts shared across repos;
run/stop from toolbar, menu, palette, CLI, deeplink.

### F. Sidebar & navigation **[GEN + CORE]**
Repository-grouped sidebar (repos → worktrees), hoisted **Pinned** & **Active**
highlight sections, per-row notification dots, **jump-to-latest-unread**
(Cmd-Shift-U), ⌃1–9 direct selection, next/prev + history back/forward,
reveal-in-sidebar, multi-select for bulk ops, plain-folder (non-git) repos.

### G. Command palette **[GEN]**
Cmd-P fuzzy search over worktrees + all actions, recency-ranked.

### H. Notifications **[GEN + CORE]**
In-app bell notifications (capture preceding terminal text), toolbar unread
popover grouped by repo, optional system notifications + custom sound, prioritize
notified worktrees to top, rich agent notifications.

### I. Customization **[LIGHT]**
Per-repo color tint (sidebar/scripts/tabs), per-worktree custom title + tint,
repo display name, Light/Dark/System appearance, terminal theme sync.

### J. Settings **[LIGHT]**
JSON-file settings (global + per-repo), full **keyboard-shortcut rebinding** UI
with conflict detection, per-agent install rows, global/repo scripts, update
channel (stable/beta), quit-confirmation policy, **analytics (PostHog) + crash
reporting (Sentry)** on by default, automated-action policy for deeplinks.

### K. CLI + L. Deeplinks **[CORE / MED]**
A bundled `supacode` CLI over a Unix socket / `supacode://` deeplinks: `open`,
`worktree {list,focus,run,stop,archive,delete,pin,…}`, `tab {list,focus,new,
close}`, `surface {list,focus,split,close}`, `repo {list,open,worktree-new}`,
`settings`. Surfaces get `SUPACODE_{WORKTREE,REPO,TAB,SURFACE}_ID` env vars so
the CLI infers context. Agents call this CLI to drive the app.

### M–P. Misc **[LIGHT]**
Sparkle auto-update (stable/beta channels), onboarding cards, open-in-editor
(VS Code/Cursor/Xcode/Zed) + reveal-in-Finder, a motivational toolbar status
("Open Command Palette ⌘P" / clock when idle).

---

## 2. What Batty already has (don't re-adopt)

Batty has independently arrived at most of supacode's *light* wins:

| supacode feature | Batty equivalent |
|---|---|
| Command palette (G) | `CommandPaletteView` + `commandPalette` action (Cmd-P) ✓ |
| Keyboard-shortcut rebinding + conflict detection (J6) | `Shortcuts/` — `ShortcutsStore`, `KeyboardShortcutRecorder`, `ShortcutsSettingsView`, collision detection ✓ |
| Session/layout presets | Layout presets + `layoutPicker` action ✓ |
| Theme picker + Light/Dark/System appearance (I4) | Theme selector + `ThemePreference`/`AppearanceObserver` (#0245) ✓ |
| In-app bell notifications + system notifications (H) | Bell Feed + system notifications + AI bell summaries (#0246) ✓ |
| File quick-open | `openQuickly` action ✓ |
| Layout/session persistence (D5) | Workspace persistence ✓ |
| CLI + URL scheme (K/L) | `batty` CLI + `batty://` scheme (#0249–#0251) ✓ |
| Sparkle auto-update (M) | Sparkle ✓ |
| Quit confirmation (J1) | `QuitConfirmation` ✓ |
| Drag files → shell-quoted paths | Drag-drop (PRD §6.12) ✓ |

Batty also has things supacode's inventory didn't emphasize: AI session
auto-naming, AI bell-notification summaries — Batty is already lightly
"AI-aware" without being an agent orchestrator.

---

## 3. Recommended to adopt (simplicity-first)

Only features that are **self-contained, generically useful, and on-brand** for a
simple personal multiplexer. None require git/GitHub/agent infrastructure.

### Tier 1 — clear wins, small surface
1. **In-terminal search (Cmd-F).** *Gap.* supacode exposes Ghostty's built-in
   search overlay (`GhosttySurfaceSearchOverlay`, D6); Batty has no find. This is
   a generic, *expected* terminal feature, mostly provided by libghostty —
   likely a thin overlay + one keybind + a `ShortcutAction` case. High value,
   low complexity, zero new infra. **Recommend first.**
2. **Open in editor + Reveal in Finder.** *Gap.* A toolbar/menu/palette action to
   open the focused session's cwd in the user's editor (VS Code/Cursor/Xcode/Zed,
   auto-detected) and reveal it in Finder (`NSWorkspace.activateFileViewerSelecting`).
   supacode's O is small and self-contained; Batty already tracks each tab's cwd,
   so this is mostly plumbing + a couple of `ShortcutAction` cases. Fits the
   "native macOS feel" goal. **Recommend.**

### Tier 2 — nice, optional polish
3. **Jump to latest unread bell (keybinding).** supacode's Cmd-Shift-U (F4)
   selects the most-recently-notified source and focuses it. Batty already has
   the bell feed + click-to-jump machinery; this is a keyboard shortcut over
   existing "bring source forward" logic. Small, complements the feed.
4. **Per-session color tint.** supacode's per-repo/worktree color (I1/I2) helps
   tell projects apart at a glance. For Batty: an optional accent color per
   *session*, shown on the sidebar row (and maybe the pane border). Pure-UI,
   persists with the workspace. Low priority; only if you want the visual cue.
5. **A few more CLI verbs.** Now that `batty` exists, a *curated* handful —
   `batty list` (sessions), `batty new [path]` (without needing the URL form),
   `batty focus <name|id>` — would round out scripting from the shell. Resist
   porting supacode's full `tab`/`surface`/`split` surface; that's agent-driver
   territory, not "simple." Add only verbs you'd actually type.

### Tier 3 — consider only if the workflow pulls you there
6. **SSH remote sessions.** supacode's D11 (ssh wrapped for persistence) maps to
   Batty's *own* v2 idea (PRD §10 "SSH connection manager"). Already deferred to
   v2; note that supacode's "just run `ssh host` in the surface" approach is the
   simple version, vs. a full connection manager.

---

## 4. Explicitly decline / keep out (protects simplicity)

These are supacode's identity and/or Batty's stated non-goals. Adopting them
would change what Batty *is*.

| Feature | Why not (for Batty) |
|---|---|
| **Agent orchestration** (A) — hooks, presence badges, OSC 3008, liveness sweeps | This *is* supacode. Heavy multi-agent infra; opposite of "simple personal multiplexer." Batty's lightweight AI touches (naming, bell summaries) are the right altitude. |
| **Git worktree management** (B) | Reframes the sidebar around git worktrees, not sessions. Heavy lifecycle + bundled `wt` CLI. Batty's unit is a *session*, deliberately. |
| **GitHub PR/CI integration** (C) | Requires authenticated `gh`, PR/CI polling, merge UI. A whole product surface; off-mission. |
| **Per-repo script system** (E) | This is automation/config-as-data. PRD non-goal: "no scripting/config language." Keep settings in the Settings window, not per-project scripts. |
| **zmx session persistence** (D4) — shells survive quit | Tempting, but PRD is explicit: relaunched shells **start fresh in the saved cwd**; "we do not restore running processes." Detach/attach is a listed non-goal. Adopting a daemon is a big complexity jump. |
| **Repository-grouped sidebar / Pinned+Active sections** (F1/F2) | Tied to the repo/worktree model. Batty's flat session list is simpler by design. |
| **Analytics + crash reporting on-by-default** (J11) | PRD: "No telemetry." Hard decline. |
| **Onboarding cards** (N) | Single-user app; not worth the surface. |

---

## 5. Summary

Batty has already absorbed supacode's *good simple ideas* (palette, rebindable
shortcuts, presets, themes, notifications, CLI) on its own terms. The short list
worth actually doing, in order:

1. **Cmd-F in-terminal search** (Tier 1 — generic gap, cheap).
2. **Open in editor / Reveal in Finder** (Tier 1 — native affordance, cheap).
3. **Jump-to-latest-unread bell shortcut** (Tier 2 — reuses bell feed).
4. *Optional:* per-session color tint; a few more `batty` CLI verbs.

Everything else — agents, worktrees, GitHub, scripts, zmx persistence, telemetry
— is what keeps supacode *and Batty* distinct. Declining it is the feature.
