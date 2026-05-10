# Batty v1 ship checklist

Gates v1.0.0 against PRD §12. Every item is verified before tagging
`v1.0.0`. Update the `Verified` column with date + initials when each
holds; if any regress later, ship is blocked until they're green again.

## Success criteria (PRD §12)

| # | Criterion | Verified |
|---|---|---|
| 1 | I've replaced my current tmux-like app with Batty for at least two weeks of daily work without falling back. |  |
| 2 | Layout persistence has survived 10+ relaunches without data loss or crashes. |  |
| 3 | The bell feed has caught at least one background event I would have otherwise missed. |  |
| 4 | No reproducible crash for a week of daily use. |  |
| 5 | The keybindings in PRD §5 all work without conflict against system shortcuts. |  |

## Build & distribution gates

| # | Item | Verified |
|---|---|---|
| B1 | `xcodebuild -scheme Batty -destination 'platform=macOS' build` passes. |  |
| B2 | `xcrun swift test --package-path BattyKit` passes. |  |
| B3 | `scripts/release.sh` produces `dist/Batty-<sha>.dmg`. |  |
| B4 | `scripts/verify-dmg.sh dist/Batty-<sha>.dmg` reports all checks green. |  |
| B5 | A clean Mac (or fresh user account) opens the DMG and launches Batty without right-click bypass and without "from an unidentified developer" warning. |  |
| B6 | Tag `v1.0.0` exists and is pushed to GitHub. |  |
| B7 | Sparkle appcast publishes a `1.0.0` `<item>` (when #0038 lands). |  |

## Functional sanity

Spot-check before tagging — these don't appear in PRD §12 explicitly but
reflect the v1 feature set:

| Area | Check | Verified |
|---|---|---|
| Sessions | Create / rename / duplicate / close from sidebar; Cmd-Option-N for new; Cmd-Option-1..9 selection. |  |
| Splits | Cmd-D and Cmd-Shift-D split; Cmd-Ctrl-arrows resize; divider drag works; ratios persist. |  |
| Tabs | Cmd-T new; Cmd-W close; Cmd-1..9 select; Cmd-Shift-[ / ] navigate; titles auto-update. |  |
| IME | CJK Romaji input, Option-E + E for `é`, Ctrl-Cmd-Space emoji picker. |  |
| Drag-drop | Dragging a file from Finder onto a pane inserts a shell-quoted path; drag-over highlight appears. |  |
| Bell feed | `printf '\a'` rings; `printf '\033]9;hello\a'` pops a system notification; bell feed popover opens via Cmd-Shift-N; click-to-jump moves focus. |  |
| Themes | View → Theme switches live; Settings → Appearance Theme picker works; choice persists. |  |
| Settings | Cmd-, opens; font size, cursor style, paste-strictness, confirm-quit, bell sound, system notifications all persist and apply. |  |
| Paste | Single-line Cmd-V pastes; multi-line Cmd-V prompts (default strictness). |  |
| Quit | Cmd-Q with terminals open prompts; cancel keeps the app up. |  |
| About | Standard About panel shows libghostty / SlidingTabs credits. |  |
| Restore | Quit, relaunch — workspace returns with sessions / panes / tabs / cwds intact. |  |

## Known limitations to disclose in v1 release notes

- **Per-tab close-confirmation** is not yet implemented. Quit-time confirmation
  covers the most-important case; per-tab will land when libghostty exposes a
  CommandStart shell-integration signal (see #0036).
- **Window-level click-to-jump** is a no-op for v1's single-window default.
  Multi-window expansion will need additional `NSWindow` plumbing (see #0027).
- **Bundled terminfo / shell-integration** is currently unbundled — `$TERM`
  falls back to `xterm-256color`. Some Ghostty-specific extensions (256-color,
  kitty keyboard protocol) silently degrade. Vendoring path tracked in #0003.
- **TerminalSurface details** (Metal sizing, IME plumbing, key event
  translation) come from the upstream `GhosttyTerminal` Swift wrapper rather
  than a hand-rolled `NSViewRepresentable` (see #0007 / #0008 — both
  effectively superseded by adopting the wrapper).

## Process

- Bump version + build number per `scripts/RELEASE.md`.
- Run the release pipeline.
- Smoke-test on a clean Mac.
- Confirm every row above is green.
- Tag and push.
- Write release notes citing closed issues for the milestone.
