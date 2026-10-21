#!/bin/zsh
# guest-setup.sh — prepare a disposable Tart clone for the demo scenes (#0505).
#
# Runs INSIDE the guest only, called by tools/run-ui-tests-vm.sh in demo mode.
# Never run it on a host Mac: it rewrites ~/.zshrc and ~/.zshenv, hides the
# Dock and installs toolchains.
#
# Usage (in the guest):
#   guest-setup.sh <path-to-built-Batty-Beta.app> [owner/repo ...]
#
# With no repos it clones the full demo set. Whatever the repos, it also
# creates the small local repos under ~/Developer/demo that the demo
# Projects open (no network needed). Everything is best effort and
# logged: a repo or tool that fails is reported on the last lines and the
# run continues, so the scene that needs it fails by name, not the setup.

set -u

APP="$1"; shift
REPOS=("$@")
(( ${#REPOS} )) || REPOS=(brennanMKE/Batty brennanMKE/laya-go brennanMKE/ShortLinks neovim/neovim tokio-rs/tokio torvalds/linux)

DEV="$HOME/Developer"
BIN="$HOME/.local/bin"
FAILED=()
mkdir -p "$DEV" "$BIN"
export PATH="$BIN:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

log() { print -r -- "[demo-setup $(date +%H:%M:%S)] $*"; }
bounded() { local secs="$1"; shift; /usr/bin/perl -e 'alarm shift; exec @ARGV' -- "$secs" "$@"; }

git config --global user.name "Batty Demo"
git config --global user.email "demo@batty.invalid"
git config --global init.defaultBranch main
git config --global advice.detachedHead false
git config --global --add safe.directory '*'

# --- Shell: what every Pane's zsh will source ----------------------------------

cat > "$HOME/.zshenv" <<'ENV'
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
export EDITOR=nvim
ENV

cat > "$HOME/.zshrc" <<'RC'
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
export EDITOR=nvim
export GIT_PAGER=cat
export CLICOLOR=1
[ -f "$HOME/.demo-arch" ] && export ARCH="$(cat "$HOME/.demo-arch")"
# XCUITest launches the app with OS_ACTIVITY_DT_MODE=YES, which makes every
# os_log line of a CLI run in a Pane print to the terminal.
unset OS_ACTIVITY_DT_MODE
# The scenes learn a command was submitted from this file (BattyUITests/DemoSceneTests).
preexec() { [[ -n "$DEMO_PREEXEC_FILE" ]] && print -r -- "$1" > "$DEMO_PREEXEC_FILE"; }
RC_BATTY_ALIAS
PROMPT='%F{141}%1~%f %F{245}>%f '
RPROMPT=''
alias ls='ls -G'
setopt NO_BEEP
RC

# --- Desktop: no Dock in the frame ---------------------------------------------

defaults write com.apple.dock autohide -bool true
defaults write com.apple.dock autohide-delay -float 1000
killall Dock >/dev/null 2>&1 || true

# --- The batty command ------------------------------------------------------------
# The ad-hoc Beta embeds the CLI as "batty"; the dangling link is fine until
# the app is built.

# An alias, not a symlink on PATH: the CLI finds its app bundle from argv[0],
# which is only a path when it is invoked by one.
rm -f "$BIN/batty"
print -r -- "alias batty='\"$APP/Contents/Resources/bin/batty\"'" > "$HOME/.demo-batty-alias"
sed -i '' "/RC_BATTY_ALIAS/{
r $HOME/.demo-batty-alias
d
}" "$HOME/.zshrc"
log "batty -> $APP/Contents/Resources/bin/batty"

# --- Repositories ---------------------------------------------------------------

clone() {
  local slug="$1" dest="$DEV/$1"
  if [[ -d "$dest/.git" ]]; then log "$slug already present"; return 0; fi
  mkdir -p "${dest:h}"
  local attempt
  for attempt in 1 2 3; do
    log "cloning $slug (attempt $attempt)"
    rm -rf "$dest"
    if bounded 1500 git clone --depth 1 --single-branch --quiet "https://github.com/$slug.git" "$dest"; then
      log "cloned $slug: $(du -sh "$dest" | cut -f1)"
      return 0
    fi
  done
  FAILED+=("clone:$slug")
  return 1
}

for slug in $REPOS; do clone "$slug" & done
wait
for slug in $REPOS; do [[ -d "$DEV/$slug/.git" ]] || FAILED+=("clone:$slug"); done

# --- Local demo Projects ----------------------------------------------------------
# Small made-up repos for the AWS, Home Assistant and Music Projects the scenes
# seed. No real hosts, keys or accounts.

local_repo() {
  local name="$1" dest="$DEV/demo/$1"
  if [[ -d "$dest/.git" ]]; then log "demo/$name already present"; return 0; fi
  rm -rf "$dest"
  mkdir -p "$dest"
  case "$name" in
    aws-infra)
      print -r -- "# aws-infra

Terraform for the static site's asset bucket." > "$dest/README.md"
      cat > "$dest/main.tf" <<'TF'
provider "aws" {
  region = var.region
}

resource "aws_s3_bucket" "assets" {
  bucket = "${var.prefix}-assets"
}
TF
      cat > "$dest/variables.tf" <<'TF'
variable "region" {
  default = "us-west-2"
}

variable "prefix" {
  default = "demo"
}
TF
      ;;
    home-assistant)
      print -r -- "# home-assistant

Configuration for the house." > "$dest/README.md"
      cat > "$dest/configuration.yaml" <<'YAML'
homeassistant:
  name: Home
  unit_system: metric

automation: !include automations.yaml
YAML
      cat > "$dest/automations.yaml" <<'YAML'
- alias: Lights on at sunset
  trigger:
    - platform: sun
      event: sunset
  action:
    - service: light.turn_on
      target:
        area_id: living_room
YAML
      ;;
    music-app)
      print -r -- "# MusicApp

A small music player." > "$dest/README.md"
      cat > "$dest/Package.swift" <<'SWIFT'
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MusicApp",
    targets: [.executableTarget(name: "MusicApp")]
)
SWIFT
      mkdir -p "$dest/Sources/MusicApp"
      cat > "$dest/Sources/MusicApp/Player.swift" <<'SWIFT'
struct Player {
    var queue: [String] = []
    var isPlaying = false

    mutating func play() { isPlaying = !queue.isEmpty }
}
SWIFT
      ;;
  esac
  if (cd "$dest" && git init -q && git add -A && git commit -qm "Initial commit"); then
    [[ "$name" == aws-infra ]] && print -r -- '
variable "environment" {
  default = "staging"
}' >> "$dest/variables.tf"
    log "created demo/$name"
  else
    FAILED+=("local:$name")
  fi
}

for name in aws-infra home-assistant music-app; do local_repo "$name"; done

# --- Toolchains -----------------------------------------------------------------

wants() { local r; for r in $REPOS; do [[ "$r" == "$1" ]] && return 0; done; return 1; }

if wants tokio-rs/tokio; then
  if ! command -v cargo >/dev/null; then
    log "installing Rust (minimal profile)"
    bounded 900 /bin/sh -c 'curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --no-modify-path' >/dev/null 2>&1 \
      || FAILED+=("tool:rust")
  fi
  if command -v cargo >/dev/null && [[ -d "$DEV/tokio-rs/tokio" ]]; then
    log "cargo fetch in tokio ($(cargo --version))"
    (cd "$DEV/tokio-rs/tokio" && bounded 900 cargo fetch --quiet) || FAILED+=("tool:cargo-fetch")
    # tokio pins a toolchain in rust-toolchain.toml in some releases; install it now.
    (cd "$DEV/tokio-rs/tokio" && bounded 600 rustc --version >/dev/null 2>&1) || FAILED+=("tool:rustc")
  fi
fi

if wants neovim/neovim || wants brennanMKE/Batty || wants brennanMKE/laya-go; then
  if ! command -v nvim >/dev/null; then
    log "installing Neovim"
    NV="$HOME/.local/nvim"
    mkdir -p "$NV"
    if bounded 300 curl -fsSL -o "$NV/nvim.tar.gz" https://github.com/neovim/neovim/releases/latest/download/nvim-macos-arm64.tar.gz \
       && tar -xzf "$NV/nvim.tar.gz" -C "$NV" --strip-components=1; then
      xattr -cr "$NV" 2>/dev/null
      ln -sf "$NV/bin/nvim" "$BIN/nvim"
    else
      FAILED+=("tool:nvim")
    fi
  fi
  command -v nvim >/dev/null && log "nvim: $(nvim --version | head -1)"
fi

# --- Linux: make defconfig for the Bell Feed clip ---------------------------------
# Try to make `make defconfig` work on macOS with a GNU Make 4+ in front of
# the system make. A shim named `make` in ~/.local/bin points at it. When the
# probe fails the marker is not written and the scene uses a Rust build.

if wants torvalds/linux && [[ -d "$DEV/torvalds/linux/.git" ]]; then
  if ! "$BIN/gmake" --version >/dev/null 2>&1; then
    log "building GNU Make 4.4.1"
    GM="$(mktemp -d)"
    if bounded 300 curl -fsSL -o "$GM/make.tar.gz" https://ftp.gnu.org/gnu/make/make-4.4.1.tar.gz \
       && tar -xzf "$GM/make.tar.gz" -C "$GM" \
       && (cd "$GM/make-4.4.1" && ./configure --prefix="$HOME/.local" --program-prefix=g >/dev/null 2>&1 && bounded 600 make -j4 >/dev/null 2>&1 && make install >/dev/null 2>&1); then
      log "gmake: $("$BIN/gmake" --version | head -1)"
    else
      FAILED+=("tool:gmake")
    fi
  fi
  if "$BIN/gmake" --version >/dev/null 2>&1; then
    ln -sf "$BIN/gmake" "$BIN/make"
    # Kconfig asks `ld --version` and rejects Apple's ld; answer as GNU ld and
    # hand every other invocation to the real linker.
    cat > "$BIN/ld" <<'LD'
#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "GNU ld (GNU Binutils) 2.42"
  exit 0
fi
exec /usr/bin/ld "$@"
LD
    chmod +x "$BIN/ld"
    print -r -- arm64 > "$HOME/.demo-arch"
    log "probing make defconfig in linux"
    if (cd "$DEV/torvalds/linux" && ARCH=arm64 bounded 600 "$BIN/gmake" defconfig > "$HOME/linux-probe.log" 2>&1); then
      log "linux defconfig works"
      touch "$HOME/.demo-linux-ok"
      (cd "$DEV/torvalds/linux" && git clean -fdxq && git checkout -q . 2>/dev/null)
    else
      log "linux defconfig FAILED; tail of the probe log:"
      tail -15 "$HOME/linux-probe.log"
      FAILED+=("probe:linux-defconfig")
      rm -f "$BIN/make"
    fi
  fi
fi

log "done. failures: ${FAILED[*]:-none}"
exit 0
