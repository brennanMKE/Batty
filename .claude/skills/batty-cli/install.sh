#!/usr/bin/env bash
set -euo pipefail

# install.sh — copy this skill folder into every detected agent host's
# skills directory (#0404).
#
# Unlike QuestSkill's install.sh (a live-checkout convenience that
# *symlinks* into a canonical local clone), this one COPIES: Batty's
# audience fetches this folder from a tagged GitHub release
# (`batty capabilities`'s printed recipe) with no canonical checkout to
# link back to, so a copy is the only shape that works for that audience.
# Because this script ships inside the skill folder itself, a tagged fetch
# of `.claude/skills/batty-cli/` carries its own installer — no separate
# download, no `scripts/` involvement (that directory is restricted).
#
# Usage:
#   ./install.sh                  Install into every detected global host dir
#   ./install.sh --project DIR    Also install into DIR's project-scoped dirs
#   ./install.sh --dry-run        Print what would happen; touch nothing
#   ./install.sh --project DIR --dry-run
#
# Hosts covered, and why (verified live + against current docs, 2026-09-10,
# see issues/0404.md for the full evidence trail):
#
#   Claude Code  ~/.claude/skills/batty-cli (global), .claude/skills (project)
#                — native format this skill already uses.
#   OpenCode     ~/.config/opencode/skills/batty-cli (global; XDG-aware) —
#                native, though OpenCode also reads ~/.claude/skills and
#                ~/.agents/skills as documented compatibility fallbacks, so
#                the Claude Code copy alone already reaches it.
#   Cursor       ~/.cursor/skills/batty-cli (global, if Cursor is present) —
#                native, co-equal with ~/.agents/skills (both are native
#                global locations per Cursor's own docs, not one primary and
#                one fallback). Cursor also reads ~/.claude/skills and
#                ~/.codex/skills for compatibility only, both globally and
#                (per-project) as .cursor/skills, .agents/skills, .claude/skills,
#                .codex/skills nested anywhere in a repo.
#   Codex        ~/.agents/skills/batty-cli (global) — current official Codex
#                docs (developers.openai.com/codex/skills, redirects to
#                learn.chatgpt.com/docs/build-skills) name $CWD/.agents/skills,
#                $REPO_ROOT/.agents/skills, and $HOME/.agents/skills as the
#                real discovery paths; CODEX_HOME customizes the user-level
#                root. Also installed to ~/.codex/skills/batty-cli (i.e.
#                $CODEX_HOME/skills) as a belt-and-suspenders copy, since
#                that directory is what this machine's live Codex install
#                actually uses for its own bundled/installer-fetched skills
#                (~/.codex/skills/.system/...) — installing to both costs
#                nothing and covers whichever convention the installed Codex
#                version honors.
#   Any other    ~/.agents/skills/batty-cli is installed unconditionally
#   agent        (not gated on any detected binary/directory) as the
#                explicit "or another type" catch-all the issue was filed
#                for — an unused directory costs nothing, and any future
#                host that adopts the emerging cross-tool `.agents/skills`
#                convention picks the skill up for free.
#
# Every copy is staged to a ".new" sibling and verified to contain SKILL.md
# before swapping over any existing install (#0403's stage-verify-swap
# discipline, applied per destination here instead of to one hardcoded
# path). If an existing destination is already byte-identical to this copy
# (the common case: refreshing when nothing changed), nothing is staged,
# backed up, or written at all. Otherwise a pre-existing install — symlink
# or not — is preserved by moving it into a backup directory *outside* the
# scanned skills root (never as a sibling inside it, which would leave a
# stale second `SKILL.md` for the host to discover and compete with the
# fresh one — round-2 review B1). Replacing a symlink is reported by name
# and target, not done silently.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      if [ $# -lt 2 ] || [ -z "$2" ]; then echo "--project requires a directory" >&2; exit 1; fi
      PROJECT_DIR="$2"; shift 2
      ;;
    --project=*) PROJECT_DIR="${1#*=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) tail -n +2 "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }

real_path() {
  # BSD `cd`/`pwd -P` round trip — no `readlink -f` on macOS's stock readlink.
  ( cd "$1" 2>/dev/null && pwd -P ) || true
}

dest_present() {
  # True if DEST exists or is a symlink (including a *broken* symlink,
  # which plain `-e` misses because it follows the link before checking).
  [ -e "$1" ] || [ -L "$1" ]
}

# install_into DEST — stage SCRIPT_DIR into DEST/.new, verify SKILL.md is
# present, preserve (never discard) any existing DEST by moving it to a
# backup path outside DEST'''s own skills root, then swap. Never touches an
# existing install before the replacement is confirmed staged, and never
# reports success without confirming each destructive step actually
# succeeded. Returns 1 (without touching DEST) if staging or the swap
# itself fails, so callers can report per-target without aborting the rest.
# The two `mkdir -p` calls silence their own stderr (a friendly line
# already follows either one'''s failure indirectly, via the stage-incomplete
# or failed-to-back-up message below); the two `mv` calls deliberately do
# not, since a permissions error, ENOSPC, and a cross-device rename all
# produce the same friendly "failed to back up"/"failed to move" wording —
# the raw system message is the only thing that names which one it was.
install_into() {
  local dest="$1"
  local parent
  parent="$(dirname "$dest")"

  if [ -e "$dest" ] && [ "$(real_path "$dest")" = "$(real_path "$SCRIPT_DIR")" ]; then
    echo "  $dest is already the canonical copy — skipped"
    return 0
  fi

  if dest_present "$dest" && diff -rq "$SCRIPT_DIR" "$dest" >/dev/null 2>&1; then
    echo "  $dest already up to date — skipped"
    return 0
  fi

  if [ "$DRY_RUN" = "1" ]; then
    if [ -L "$dest" ]; then
      echo "  [dry-run] would replace existing symlink $dest -> $(readlink "$dest")"
    elif [ -e "$dest" ]; then
      echo "  [dry-run] would back up existing $dest and install a fresh copy"
    else
      echo "  [dry-run] would install into $dest"
    fi
    return 0
  fi

  mkdir -p "$parent" 2>/dev/null
  rm -rf "$dest.new"
  if cp -R "$SCRIPT_DIR" "$dest.new" && [ -f "$dest.new/SKILL.md" ]; then
    if dest_present "$dest"; then
      if [ -L "$dest" ]; then
        echo "  replacing existing symlink $dest -> $(readlink "$dest")"
      fi
      local backup_root
      backup_root="$(dirname "$parent")/batty-cli-skill-backups"
      mkdir -p "$backup_root" 2>/dev/null
      local backup
      backup="$backup_root/$(basename "$dest").$(date +%Y%m%d%H%M%S).$$"
      if ! mv -- "$dest" "$backup"; then
        echo "  failed to back up existing $dest — leaving it in place, not installing" >&2
        rm -rf "$dest.new"
        return 1
      fi
      echo "  backed up existing $dest to $backup"
    fi
    if ! mv "$dest.new" "$dest"; then
      echo "  failed to move the staged copy into $dest — nothing usable is at $dest right now, check $dest.new" >&2
      return 1
    fi
    echo "  installed $dest"
  else
    echo "  stage incomplete for $dest — existing copy left untouched" >&2
    rm -rf "$dest.new"
    return 1
  fi
}

# Round-2 review N9: `install_into`'s own per-destination return code used to
# feed a single INSTALLED_ANY flag, which only ever asked "did *anything*
# succeed" — a partial failure (one destination fails, another succeeds)
# printed "Done." and exited 0. An agent following SKILL.md's or
# capabilities' instructions to run this script checks $? once, not each
# destination's own output line; a 0 there is exactly the #0383 skew
# arriving through the exit code instead of a stale flag. DESTINATION_COUNT
# and FAILED_COUNT below make partial failure visible in both the summary
# line and the exit code.
DESTINATION_COUNT=0
FAILED_COUNT=0

try_install() {
  DESTINATION_COUNT=$((DESTINATION_COUNT + 1))
  install_into "$1" || FAILED_COUNT=$((FAILED_COUNT + 1))
}

echo "batty-cli agent skill installer"
if [ "$DRY_RUN" = "1" ]; then echo "(dry run — nothing will be written)"; fi

if have claude || [ -d "$HOME/.claude" ]; then
  echo "Claude Code:"
  try_install "$HOME/.claude/skills/batty-cli"
fi

OPENCODE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
if have opencode || [ -d "$OPENCODE_DIR" ]; then
  echo "OpenCode:"
  try_install "$OPENCODE_DIR/skills/batty-cli"
fi

if have cursor || [ -d "$HOME/.cursor" ]; then
  echo "Cursor (global):"
  try_install "$HOME/.cursor/skills/batty-cli"
fi

CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
if have codex || [ -d "$CODEX_HOME_DIR" ]; then
  echo "Codex ($CODEX_HOME_DIR/skills):"
  try_install "$CODEX_HOME_DIR/skills/batty-cli"
fi

echo "Cross-tool (~/.agents/skills — Codex's documented native path, also read by Cursor/OpenCode):"
try_install "$HOME/.agents/skills/batty-cli"

if [ -n "$PROJECT_DIR" ]; then
  echo "Project-scoped ($PROJECT_DIR):"
  try_install "$PROJECT_DIR/.claude/skills/batty-cli"
  try_install "$PROJECT_DIR/.cursor/skills/batty-cli"
  try_install "$PROJECT_DIR/.agents/skills/batty-cli"
fi

if [ "$DRY_RUN" != "1" ]; then
  if [ "$FAILED_COUNT" -gt 0 ]; then
    echo "$FAILED_COUNT of $DESTINATION_COUNT destinations failed — see messages above" >&2
    exit 1
  fi
  echo "Done."
fi
